## Manages AI state replication from host to clients.
## Host broadcasts active AI positions, states, and animation data at ~10Hz.
## Clients interpolate and drive AI visuals from the received snapshots.
## Events (activation, death, fire) are sent as reliable RPCs.
##
## Sync IDs are flat integers: 0..spawnPool-1 for A_Pool, spawnPool..N for B_Pool.
## All lookups use direct array indexing — no dictionary hashing or string keys.
extends Node

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager



## Send every 12th physics tick: 120Hz / 12 = 10Hz.
const SEND_EVERY_N_TICKS: int = 12
## Interpolation delay in seconds. Two packets at 10Hz covers jitter.
const INTERP_DELAY: float = 0.15
## Maximum buffered snapshots per AI before oldest is discarded.
const MAX_BUFFER_SIZE: int = 10

## AI state enum — mirrors [code]AI.gd[/code]'s [code]State[/code] enum order.
## IMPORTANT: must match [code]enum State[/code] in [code]Scripts/AI.gd:55[/code].
## Verify after every game update.
enum AIState {
    IDLE, WANDER, GUARD, PATROL, HIDE, AMBUSH, COVER,
    DEFEND, SHIFT, COMBAT, HUNT, ATTACK, VANTAGE, RETURN,
}

## Animator condition lookup tables indexed by AIState enum value.
## Direct access: IS_MOVEMENT[snap.state]. Avoids per-tick allocation.
static var IS_MOVEMENT: PackedInt32Array = _build_state_mask([
    AIState.WANDER, AIState.PATROL, AIState.HIDE, AIState.COVER,
    AIState.SHIFT, AIState.VANTAGE, AIState.RETURN, AIState.ATTACK,
])
static var IS_GUARD: PackedInt32Array = _build_state_mask([
    AIState.IDLE, AIState.GUARD, AIState.AMBUSH,
])


static func _build_state_mask(states: Array[int]) -> PackedInt32Array:
    var mask: PackedInt32Array = []
    mask.resize(AIState.RETURN + 1)
    mask.fill(0)
    for s: int in states:
        mask[s] = 1
    return mask

## Precomputed animator parameter paths as StringName (avoids per-tick String allocation).
const COND_PISTOL: StringName = &"parameters/conditions/Pistol"
const COND_RIFLE: StringName = &"parameters/conditions/Rifle"
const COND_MOVEMENT: StringName = &"parameters/conditions/Movement"
const COND_COMBAT: StringName = &"parameters/conditions/Combat"
const COND_HUNT: StringName = &"parameters/conditions/Hunt"
const COND_DEFEND: StringName = &"parameters/conditions/Defend"
const COND_GUARD: StringName = &"parameters/conditions/Guard"
const BLEND_PISTOL_MOVE: StringName = &"parameters/Pistol/Movement/blend_position"
const BLEND_PISTOL_COMBAT: StringName = &"parameters/Pistol/Combat/blend_position"
const BLEND_PISTOL_HUNT: StringName = &"parameters/Pistol/Hunt/blend_position"
const BLEND_RIFLE_MOVE: StringName = &"parameters/Rifle/Movement/blend_position"
const BLEND_RIFLE_COMBAT: StringName = &"parameters/Rifle/Combat/blend_position"
const BLEND_RIFLE_HUNT: StringName = &"parameters/Rifle/Hunt/blend_position"

## Flags bitfield for per-AI boolean state.
enum AIFlag {
    DEAD = 1,
    IMPACT = 2,
    PISTOL = 4,
}


## A single network snapshot for one AI entity.
class AISnapshot extends RefCounted:
    var timestamp: float
    var position: Vector3
    var rotation_y: float
    var state: int
    var move_speed: float
    var strafe: float
    var health: int
    var flags: int


    func _init(t: float, p: Vector3, ry: float, s: int, ms: float, st: float, h: int, f: int) -> void:
        timestamp = t
        position = p
        rotation_y = ry
        state = s
        move_speed = ms
        strafe = st
        health = h
        flags = f


## Per-AI ring buffer. Fixed-size, O(1) insert, no shifting.
## [member head] is the index of the oldest entry. [member count] is the number of valid entries.
## Entries are read oldest-to-newest: slots[(head + i) % capacity] for i in count.
class AIBuffer extends RefCounted:
    var slots: Array[AISnapshot] = []
    var head: int = 0
    var count: int = 0
    var capacity: int = 0


    func _init(cap: int = 10) -> void:
        capacity = cap
        slots.resize(cap)
        for i: int in cap:
            slots[i] = AISnapshot.new(0.0, Vector3.ZERO, 0.0, 0, 0.0, 0.0, 0, 0)


    ## Pushes a snapshot into the ring. Overwrites oldest if full.
    func push(snap: AISnapshot) -> void:
        var writeIdx: int = (head + count) % capacity
        slots[writeIdx] = snap
        if count < capacity:
            count += 1
        else:
            head = (head + 1) % capacity


    ## Returns the i-th entry (0 = oldest, count-1 = newest).
    func get_at(i: int) -> AISnapshot:
        return slots[(head + i) % capacity]


    ## Returns the newest entry.
    func newest() -> AISnapshot:
        return slots[(head + count - 1) % capacity]


## Total slot count (A_Pool + B_Pool). Set by [method register_spawner_pools].
var slotCount: int = 0
## Flat arrays indexed by sync ID (0..slotCount-1). Direct access, no hashing.
var aiNodes: Array[Node] = []
var aiBuffers: Array[AIBuffer] = []
## 0 = inactive on client, 1 = active (reparented to Agents).
var activeOnClient: PackedInt32Array = []
## Buffered receive_ai_activate calls that arrived before register_spawner_pools ran.
## Flushed inside register_spawner_pools once aiNodes is populated.
var pendingActivations: Array[Dictionary] = []

# ---------- Registration ----------


## Registers all AI nodes from the AISpawner for sync ID lookup.
## Scans all three containers (A_Pool, B_Pool, Agents) since
## initial spawns may have already reparented some agents out of the pools.
## If no [code]ai_sync_id[/code] metas exist (e.g. [code]_ready()[/code] took the super path
## because CoopManager wasn't available yet), assigns them deterministically here.
func register_spawner_pools(spawner: Node) -> void:
    # Collect all AI nodes from pools + active agents to find max sync ID
    var allNodes: Array[Node] = []
    var maxId: int = -1
    for container_name: String in ["A_Pool", "B_Pool", "Agents"]:
        var container: Node = spawner.get_node_or_null(container_name)
        if container == null:
            continue
        for child: Node in container.get_children():
            if child.has_meta(&"ai_sync_id"):
                allNodes.append(child)
                var idx: int = child.get_meta(&"ai_sync_id")
                if idx > maxId:
                    maxId = idx

    # If no sync IDs were assigned (spawner _ready took super path), assign now
    if allNodes.is_empty():
        allNodes = _assign_sync_ids_from_spawner(spawner)
        for child: Node in allNodes:
            var idx: int = child.get_meta(&"ai_sync_id")
            if idx > maxId:
                maxId = idx

    slotCount = maxId + 1 if maxId >= 0 else 0

    aiNodes.clear()
    aiNodes.resize(slotCount)
    aiBuffers.clear()
    aiBuffers.resize(slotCount)
    activeOnClient.resize(slotCount)
    activeOnClient.fill(0)

    for i: int in slotCount:
        aiBuffers[i] = AIBuffer.new()

    var agentsNode: Node = spawner.get_node_or_null("Agents")
    var activeCount: int = 0
    for child: Node in allNodes:
        var idx: int = child.get_meta(&"ai_sync_id")
        aiNodes[idx] = child
        # Mark already-active agents (reparented to Agents by initial spawns or late join)
        if agentsNode != null && child.get_parent() == agentsNode:
            activeOnClient[idx] = 1
            activeCount += 1
    _log("register_spawner_pools: slotCount=%d nodes=%d active=%d" % [slotCount, allNodes.size(), activeCount])

    # Flush any buffered activations that arrived before pools were ready.
    if !pendingActivations.is_empty():
        var flushed: int = 0
        for pending: Dictionary in pendingActivations:
            var pid: int = pending.get("syncId", -1)
            if pid < 0 || pid >= slotCount:
                continue
            var pnode: Node = aiNodes[pid]
            if !is_instance_valid(pnode):
                continue
            _activate_on_client(pid, pnode)
            pnode.global_position = pending.get("pos", Vector3.ZERO)
            pnode.global_rotation.y = pending.get("rotY", 0.0)
            flushed += 1
        _log("Flushed %d pending activations" % flushed)
        pendingActivations.clear()

## Assigns deterministic sync IDs to AI pool children when the spawner patch's
## [code]_ready()[/code] couldn't (e.g. CoopManager wasn't available yet).
## ONLY assigns to A_Pool and B_Pool children — agents already reparented to
## Agents are skipped because host/client pool counts diverge after spawns.
## Returns the array of all tagged nodes (pools + any pre-tagged Agents).
func _assign_sync_ids_from_spawner(spawner: Node) -> Array[Node]:
    var allNodes: Array[Node] = []
    var idx: int = 0
    # Assign IDs to pool children only — deterministic on both host and client
    for container_name: String in ["A_Pool", "B_Pool"]:
        var container: Node = spawner.get_node_or_null(container_name)
        if container == null:
            continue
        for child: Node in container.get_children():
            child.set_meta(&"ai_sync_id", idx)
            allNodes.append(child)
            idx += 1
    # Tag agents already reparented from pools (host only — spawned before this ran)
    var agentsNode: Node = spawner.get_node_or_null("Agents")
    if agentsNode != null:
        for child: Node in agentsNode.get_children():
            child.set_meta(&"ai_sync_id", idx)
            allNodes.append(child)
            idx += 1
    if idx > 0:
        _log("_assign_sync_ids_from_spawner: assigned 0..%d (%d total)" % [idx - 1, idx])
    else:
        _log("_assign_sync_ids_from_spawner: no AI nodes found")
    return allNodes

# ---------- Host Broadcast (10Hz) ----------


func _physics_process(_delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        return

    if _cm.isHost:
        _host_tick()
    else:
        _client_interpolate()


func _host_tick() -> void:
    if Engine.get_physics_frames() % SEND_EVERY_N_TICKS != 0:
        return

    var spawner: Node = _get_spawner()
    if spawner == null:
        return
    var agentsNode: Node = spawner.get_node_or_null("Agents")
    if agentsNode == null || agentsNode.get_child_count() == 0:
        return

    var ids: PackedInt32Array = []
    var positions: PackedVector3Array = []
    var rotations: PackedFloat32Array = []
    var states: PackedInt32Array = []
    var speeds: PackedFloat32Array = []
    var strafes: PackedFloat32Array = []
    var healths: PackedInt32Array = []
    var flagsArr: PackedInt32Array = []

    for child: Node in agentsNode.get_children():
        if !child.has_meta(&"ai_sync_id"):
            continue
        ids.append(child.get_meta(&"ai_sync_id"))
        positions.append(child.global_position)
        rotations.append(child.global_rotation.y)
        states.append(child.currentState)
        speeds.append(child.movementSpeed)
        # Strafe direction from combat poles
        var strafe: float = 0.0
        if child.get("north") == true:
            strafe = 1.0
        elif child.get("south") == true:
            strafe = -1.0
        strafes.append(strafe)
        healths.append(clampi(roundi(child.health), 0, 255))
        var f: int = 0
        if child.dead:
            f |= AIFlag.DEAD
        if child.get("impact") == true:
            f |= AIFlag.IMPACT
        if child.get("weapon") != null:
            var wData: Variant = child.get("weaponData")
            if wData != null && wData.get("weaponType") == "Pistol":
                f |= AIFlag.PISTOL
        flagsArr.append(f)

    if ids.is_empty():
        return
    if Engine.get_physics_frames() % (SEND_EVERY_N_TICKS * 100) == 0:
        _log("_host_tick: broadcasting %d AI" % ids.size())
    receive_ai_batch.rpc(ids, positions, rotations, states, speeds, strafes, healths, flagsArr)

# ---------- Client Receive ----------


## Receives batch AI state from host. Unreliable, 10Hz.
@rpc("authority", "call_remote", "unreliable")
func receive_ai_batch(
    ids: PackedInt32Array,
    positions: PackedVector3Array,
    rotations: PackedFloat32Array,
    states: PackedInt32Array,
    speeds: PackedFloat32Array,
    strafes: PackedFloat32Array,
    healths: PackedInt32Array,
    flagsArr: PackedInt32Array,
) -> void:
    var now: float = Time.get_ticks_msec() / 1000.0
    for i: int in ids.size():
        var idx: int = ids[i]
        if idx < 0 || idx >= slotCount:
            continue
        var buf: AIBuffer = aiBuffers[idx]
        var snap: AISnapshot = AISnapshot.new(
            now, positions[i], rotations[i], states[i],
            speeds[i], strafes[i], healths[i], flagsArr[i],
        )
        buf.push(snap)

# ---------- Client Interpolation ----------


## Reusable scratch snapshot for interpolation — avoids allocating a RefCounted per AI per tick.
var _interpSnap: AISnapshot = AISnapshot.new(0.0, Vector3.ZERO, 0.0, 0, 0.0, 0.0, 0, 0)


func _client_interpolate() -> void:
    var now: float = Time.get_ticks_msec() / 1000.0
    var renderTime: float = now - INTERP_DELAY
    var buf: AIBuffer = null
    var node: Node = null
    var from: AISnapshot = null
    var to: AISnapshot = null
    var count: int = 0
    var timeDiff: float = 0.0
    var t: float = 0.0

    for idx: int in slotCount:
        buf = aiBuffers[idx]
        count = buf.count
        if count == 0:
            continue

        node = aiNodes[idx]
        if !is_instance_valid(node):
            continue

        # Ensure this AI is visually active on the client
        if activeOnClient[idx] == 0:
            _activate_on_client(idx, node)

        if count < 2:
            _apply_snapshot(node, buf.get_at(0))
            continue

        # Find bracketing snapshots (oldest to newest via ring)
        from = buf.newest()
        to = from
        for j: int in range(1, count):
            if buf.get_at(j).timestamp >= renderTime:
                from = buf.get_at(j - 1)
                to = buf.get_at(j)
                break

        # No pruning needed — ring buffer overwrites oldest on push

        # Interpolation factor
        timeDiff = to.timestamp - from.timestamp
        t = 0.0
        if timeDiff > 0.0:
            t = clampf((renderTime - from.timestamp) / timeDiff, 0.0, 1.0)

        # Mutate reusable scratch snapshot instead of allocating
        _interpSnap.timestamp = renderTime
        _interpSnap.position = from.position.lerp(to.position, t)
        _interpSnap.rotation_y = lerp_angle(from.rotation_y, to.rotation_y, t)
        _interpSnap.state = to.state
        _interpSnap.move_speed = lerpf(from.move_speed, to.move_speed, t)
        _interpSnap.strafe = lerpf(from.strafe, to.strafe, t)
        _interpSnap.health = to.health
        _interpSnap.flags = to.flags
        _apply_snapshot(node, _interpSnap)


## Applies a snapshot to an AI node on the client: position, rotation, animation.
## Skips dead AI — once Death() ragdoll fires, snapshots must not overwrite position.
func _apply_snapshot(node: Node, snap: AISnapshot) -> void:
    if (snap.flags & AIFlag.DEAD) != 0:
        return
    node.global_position = snap.position
    node.global_rotation.y = snap.rotation_y

    # Drive animator if available
    var animator: AnimationTree = node.get("animator")
    if !is_instance_valid(animator):
        return
    if !animator.active:
        animator.active = true

    var isPistol: bool = (snap.flags & AIFlag.PISTOL) != 0

    # Set animator conditions based on AI state
    animator[COND_PISTOL] = isPistol
    animator[COND_RIFLE] = !isPistol
    animator[COND_MOVEMENT] = IS_MOVEMENT[snap.state] == 1
    animator[COND_COMBAT] = snap.state == AIState.COMBAT
    animator[COND_HUNT] = snap.state == AIState.HUNT
    animator[COND_DEFEND] = snap.state == AIState.DEFEND
    animator[COND_GUARD] = IS_GUARD[snap.state] == 1

    # Blend positions for movement/combat/hunt
    if isPistol:
        animator[BLEND_PISTOL_MOVE] = snap.move_speed
        animator[BLEND_PISTOL_COMBAT] = snap.strafe
        animator[BLEND_PISTOL_HUNT] = snap.move_speed
    else:
        animator[BLEND_RIFLE_MOVE] = snap.move_speed
        animator[BLEND_RIFLE_COMBAT] = snap.strafe
        animator[BLEND_RIFLE_HUNT] = snap.move_speed


## Activates an AI node on the client for visual display.
## Reparents from pool to Agents, shows it, enables animator.
func _activate_on_client(idx: int, node: Node) -> void:
    activeOnClient[idx] = 1
    var spawner: Node = _get_spawner()
    if spawner == null:
        return
    var agentsNode: Node = spawner.get_node_or_null("Agents")
    if agentsNode == null:
        return
    if node.get_parent() != agentsNode:
        node.reparent(agentsNode)
    node.show()
    # Keep AI paused on client — we drive it via snapshots, not AI logic
    node.set("pause", true)
    node.set("sensorActive", false)

# ---------- Activation / Deactivation Events ----------


## Host broadcasts that an AI was activated (spawned into the world).
func broadcast_ai_activate(syncId: int, pos: Vector3, rotY: float, stateIdx: int) -> void:
    _log("broadcast_ai_activate: syncId=%d pos=%s state=%d" % [syncId, str(pos), stateIdx])
    receive_ai_activate.rpc(syncId, pos, rotY, stateIdx)


## Client receives activation — reparents the matching pool child.
## If aiNodes isn't populated yet (register_spawner_pools hasn't run due to
## deferred scheduling), buffer the activation and flush it in register_spawner_pools.
@rpc("authority", "call_remote", "reliable")
func receive_ai_activate(syncId: int, pos: Vector3, rotY: float, stateIdx: int) -> void:
    if slotCount == 0 || syncId < 0 || syncId >= slotCount || !is_instance_valid(aiNodes[syncId]):
        pendingActivations.append({
            "syncId": syncId, "pos": pos, "rotY": rotY, "stateIdx": stateIdx,
        })
        _log("receive_ai_activate: buffered syncId=%d (slotCount=%d)" % [syncId, slotCount])
        return
    var node: Node = aiNodes[syncId]
    _log("receive_ai_activate: syncId=%d pos=%s" % [syncId, str(pos)])
    _activate_on_client(syncId, node)
    node.global_position = pos
    node.global_rotation.y = rotY


## Host broadcasts that an AI died.
func broadcast_ai_death(syncId: int, direction: Vector3, force: float) -> void:
    _log("broadcast_ai_death: syncId=%d" % syncId)
    receive_ai_death.rpc(syncId, direction, force)


## Client receives death — triggers ragdoll on the AI node.
## Guards against double-death if batch sync with DEAD flag also arrives.
@rpc("authority", "call_remote", "reliable")
func receive_ai_death(syncId: int, direction: Vector3, force: float) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    if node.get("dead") == true:
        return
    if node.has_method("Death"):
        node.Death(direction, force)


## Host broadcasts that an AI fired its weapon.
func broadcast_ai_fire(syncId: int) -> void:
    _log("broadcast_ai_fire: syncId=%d" % syncId)
    receive_ai_fire.rpc(syncId)


## Client receives fire event — plays audio and muzzle VFX.
@rpc("authority", "call_remote", "reliable")
func receive_ai_fire(syncId: int) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    if node.has_method("PlayFire"):
        node.PlayFire()
    if node.has_method("MuzzleVFX"):
        node.MuzzleVFX()


## Client requests host to apply damage to an AI. Host validates and applies.
@rpc("any_peer", "call_remote", "reliable")
func request_ai_damage_from_client(syncId: int, hitbox: String, damage: float) -> void:
    if !_cm.isHost:
        return
    if syncId < 0 || syncId >= slotCount:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    if node.get("dead") == true:
        return
    if node.has_method("WeaponDamage"):
        # Call the original (super) WeaponDamage, not the patched one,
        # to avoid re-routing back to the client
        node.WeaponDamage(hitbox, damage)


## Host tells a specific client they took damage from AI.
func send_ai_damage_to_peer(peerId: int, damage: float, penetration: int) -> void:
    receive_ai_damage.rpc_id(peerId, damage, penetration)


## Client receives AI damage — applies to local player's Character node.
## Matches the original AI.gd Raycast pattern: hitCollider.get_child(0).WeaponDamage()
## Character.WeaponDamage(damage, penetration) randomizes hitbox internally.
@rpc("authority", "call_remote", "reliable")
func receive_ai_damage(damage: float, penetration: int) -> void:
    var controller: Node = get_tree().current_scene.get_node_or_null("Core/Controller")
    if !is_instance_valid(controller):
        return
    # Character is the first child of Controller, same as original AI.gd:1389
    var character: Node = controller.get_child(0) if controller.get_child_count() > 0 else null
    if is_instance_valid(character) && character.has_method("WeaponDamage"):
        character.WeaponDamage(damage, penetration)


## Sends explosion damage to a specific remote peer. Host only.
func send_explosion_damage_to_peer(peerId: int) -> void:
    receive_explosion_damage.rpc_id(peerId)


## Client receives explosion damage — applies to local player's Character node.
@rpc("authority", "call_remote", "reliable")
func receive_explosion_damage() -> void:
    var controller: Node = get_tree().current_scene.get_node_or_null("Core/Controller")
    if !is_instance_valid(controller):
        return
    var character: Node = controller.get_child(0) if controller.get_child_count() > 0 else null
    if is_instance_valid(character) && character.has_method("ExplosionDamage"):
        character.ExplosionDamage()

# ---------- Full State (Late Join) ----------


## Sends all active AI to a specific peer. Called by host on peer join.
func send_full_state(peerId: int) -> void:
    if !_cm.isHost:
        return
    var spawner: Node = _get_spawner()
    if spawner == null:
        _log("send_full_state: no spawner found")
        return
    var agentsNode: Node = spawner.get_node_or_null("Agents")
    if agentsNode == null:
        _log("send_full_state: no Agents node")
        return
    var sentCount: int = 0
    for child: Node in agentsNode.get_children():
        if !child.has_meta(&"ai_sync_id"):
            continue
        if child.get("dead") == true:
            continue
        var idx: int = child.get_meta(&"ai_sync_id")
        receive_ai_activate.rpc_id(peerId, idx, child.global_position, child.global_rotation.y, child.currentState)
        sentCount += 1
    _log("send_full_state: sent %d active AI to peer %d" % [sentCount, peerId])

# ---------- Cleanup ----------


## Clears all tracking state. Called on scene change.
func clear() -> void:
    _log("clear: resetting (was slotCount=%d)" % slotCount)
    slotCount = 0
    aiBuffers.clear()
    aiNodes.clear()
    activeOnClient.resize(0)
    pendingActivations.clear()


## Removes a specific AI from tracking (e.g., after death + cleanup).
func untrack(syncId: int) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    aiNodes[syncId] = null
    aiBuffers[syncId] = AIBuffer.new()
    activeOnClient[syncId] = 0

# ---------- Utility ----------


func _get_spawner() -> Node:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return null
    return scene.get_node_or_null("AI")


func _log(msg: String) -> void:
    if is_instance_valid(_cm):
        _cm._log("[AIState] %s" % msg)
    else:
        print("[AIState] %s" % msg)
