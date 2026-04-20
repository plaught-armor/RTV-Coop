## Manages AI state replication from host to clients.
## Host broadcasts active AI positions, states, and animation data at ~10Hz.
## Clients interpolate and drive AI visuals from the received snapshots.
## Events (activation, death, fire) are sent as reliable RPCs.
##
## Sync IDs are flat integers: 0..spawnPool-1 for A_Pool, spawnPool..N for B_Pool.
## All lookups use direct array indexing — no dictionary hashing or string keys.
extends Node

var _cm: Node
## Cached local player refs, refreshed per scene transition.
var _controller: Node = null
var _character: Node = null
## Cached [code]/root/Map/AI[/code] spawner and its [code]Agents[/code] child.
## Populated by [method refresh_scene_cache]; falls back to a scene-walk in
## [method _get_spawner] if the cache goes stale mid-scene.
var _spawner: Node = null
var _agentsNode: Node = null


func init_manager(manager: Node) -> void:
    _cm = manager


## Called from [method CoopManager.on_scene_changed].
func refresh_scene_cache() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        _controller = null
        _character = null
        _spawner = null
        _agentsNode = null
        return
    _controller = scene.get_node_or_null(^"Core/Controller")
    _character = _controller.get_child(0) if is_instance_valid(_controller) && _controller.get_child_count() > 0 else null
    _spawner = scene.get_node_or_null(^"AI")
    _agentsNode = _spawner.get_node_or_null(^"Agents") if is_instance_valid(_spawner) else null



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

const _Perf: GDScript = preload("res://mod/network/perf.gd")


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
## Top-level Pistol vs Rifle switch — selects which inner state machine drives bones.
const COND_PISTOL: StringName = &"parameters/conditions/Pistol"
const COND_RIFLE: StringName = &"parameters/conditions/Rifle"
## Per-state conditions live INSIDE the Rifle / Pistol state machines, not at
## the top level. Set both halves so whichever weapon-machine is active picks
## up the new state. Path layout verified against AI_Bandit.tscn line 17873+.
const COND_RIFLE_MOVEMENT: StringName = &"parameters/Rifle/conditions/Movement"
const COND_RIFLE_COMBAT: StringName = &"parameters/Rifle/conditions/Combat"
const COND_RIFLE_HUNT: StringName = &"parameters/Rifle/conditions/Hunt"
const COND_RIFLE_DEFEND: StringName = &"parameters/Rifle/conditions/Defend"
const COND_RIFLE_GUARD: StringName = &"parameters/Rifle/conditions/Guard"
const COND_RIFLE_GROUP: StringName = &"parameters/Rifle/conditions/Group"
const COND_PISTOL_MOVEMENT: StringName = &"parameters/Pistol/conditions/Movement"
const COND_PISTOL_COMBAT: StringName = &"parameters/Pistol/conditions/Combat"
const COND_PISTOL_HUNT: StringName = &"parameters/Pistol/conditions/Hunt"
const COND_PISTOL_DEFEND: StringName = &"parameters/Pistol/conditions/Defend"
const COND_PISTOL_GUARD: StringName = &"parameters/Pistol/conditions/Guard"
const COND_PISTOL_GROUP: StringName = &"parameters/Pistol/conditions/Group"
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


## Voice broadcast types. Kept as enum so [code]ai_patch._broadcast_voice[/code]
## and [method receive_ai_voice] agree on the wire value.
enum VoiceType {
    IDLE = 0,
    COMBAT = 1,
    DAMAGE = 2,
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


    ## Mutates the next ring slot in-place — avoids per-RPC allocation.
    func push_fields(timestamp: float, position: Vector3, rotation_y: float, state: int, move_speed: float, strafe: float, health: int, flags: int) -> void:
        var writeIdx: int = (head + count) % capacity
        var slot: AISnapshot = slots[writeIdx]
        slot.timestamp = timestamp
        slot.position = position
        slot.rotation_y = rotation_y
        slot.state = state
        slot.move_speed = move_speed
        slot.strafe = strafe
        slot.health = health
        slot.flags = flags
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
    # Prime the scene-cache with the authoritative spawner passed in here so
    # later _host_tick / _activate_on_client calls hit the cache instead of
    # walking the tree every 10Hz.
    _spawner = spawner
    _agentsNode = spawner.get_node_or_null(^"Agents") if is_instance_valid(spawner) else null

    var scanResult: Dictionary = _collect_tagged_ai_nodes(spawner)
    var allNodes: Array[Node] = scanResult.nodes
    var maxId: int = scanResult.maxId

    # If no sync IDs were assigned (spawner _ready took super path), assign now
    if allNodes.is_empty():
        allNodes = _assign_sync_ids_from_spawner(spawner)
        for child: Node in allNodes:
            var idx: int = child.get_meta(&"ai_sync_id")
            if idx > maxId:
                maxId = idx

    slotCount = maxId + 1 if maxId >= 0 else 0
    _resize_slot_arrays()

    var activeCount: int = _populate_slot_arrays(allNodes)
    _log("register_spawner_pools: slotCount=%d nodes=%d active=%d" % [slotCount, allNodes.size(), activeCount])

    _flush_pending_activations()


## Walks A_Pool, B_Pool, and Agents on the spawner and collects every child that
## already carries an [code]ai_sync_id[/code] meta, also tracking the max id seen.
func _collect_tagged_ai_nodes(spawner: Node) -> Dictionary:
    var out: Array[Node] = []
    var maxId: int = -1
    for container_name: String in ["A_Pool", "B_Pool", "Agents"]:
        var container: Node = spawner.get_node_or_null(container_name)
        if container == null:
            continue
        for child: Node in container.get_children():
            if !child.has_meta(&"ai_sync_id"):
                continue
            out.append(child)
            var idx: int = child.get_meta(&"ai_sync_id")
            if idx > maxId:
                maxId = idx
    return {"nodes": out, "maxId": maxId}


## Per-AI cache of last-applied state + move_speed. Skips redundant animator
## writes in [method _apply_snapshot] when nothing changed (host broadcasts
## at 10Hz, client interp at 60Hz, so most ticks see the same state).
var _lastAppliedState: PackedInt32Array = []
var _lastAppliedSpeed: PackedFloat32Array = []
const SPEED_EPSILON: float = 0.01


## Resets aiNodes, aiBuffers, and activeOnClient to match the current slotCount.
func _resize_slot_arrays() -> void:
    aiNodes.clear()
    aiNodes.resize(slotCount)
    aiBuffers.clear()
    aiBuffers.resize(slotCount)
    activeOnClient.resize(slotCount)
    activeOnClient.fill(0)
    _lastAppliedState.resize(slotCount)
    _lastAppliedState.fill(-1)
    _lastAppliedSpeed.resize(slotCount)
    _lastAppliedSpeed.fill(-999.0)
    for i: int in slotCount:
        aiBuffers[i] = AIBuffer.new()


## Fills aiNodes by sync-id and flags agents that are already reparented to
## Agents as active. Returns the number of agents flagged active.
func _populate_slot_arrays(allNodes: Array[Node]) -> int:
    var activeCount: int = 0
    for child: Node in allNodes:
        var idx: int = child.get_meta(&"ai_sync_id")
        aiNodes[idx] = child
        if _agentsNode != null && child.get_parent() == _agentsNode:
            activeOnClient[idx] = 1
            activeCount += 1
    return activeCount


## Replays activations that arrived before the pools were populated. Bad/stale
## ids are silently skipped — we can't do anything useful with them.
func _flush_pending_activations() -> void:
    if pendingActivations.is_empty():
        return
    var flushed: int = 0
    for pending: Dictionary in pendingActivations:
        var pid: int = pending.get(&"syncId", -1)
        if pid < 0 || pid >= slotCount:
            continue
        var pnode: Node = aiNodes[pid]
        if !is_instance_valid(pnode):
            continue
        _activate_on_client(pid, pnode)
        pnode.global_position = pending.get(&"pos", Vector3.ZERO)
        pnode.global_rotation.y = pending.get(&"rotY", 0.0)
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
    if _agentsNode != null:
        for child: Node in _agentsNode.get_children():
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
    _Perf.tick()
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        return

    if _cm.isHost:
        _host_tick()
    else:
        _client_interpolate()


func _host_tick() -> void:
    var frame: int = Engine.get_physics_frames()
    if frame % SEND_EVERY_N_TICKS != 0:
        return

    if !is_instance_valid(_agentsNode):
        if _get_spawner() == null || !is_instance_valid(_agentsNode):
            return
    if _agentsNode.get_child_count() == 0:
        return

    var batch: Array = pack_ai_batch(_agentsNode)
    if batch.is_empty():
        return
    if frame % (SEND_EVERY_N_TICKS * 100) == 0:
        _log("_host_tick: broadcasting %d AI" % batch[0].size())
    # Only broadcast to peers on the host's current map. Clients on other maps
    # receive their AI via headless_map._physics_process; sending them host's
    # map data would overlap and corrupt their aiNodes indexing.
    for peerId: int in _cm.connectedPeers:
        if !_cm.is_peer_on_same_map(peerId):
            continue
        receive_ai_batch.rpc_id(peerId, batch[0], batch[1], batch[2], batch[3], batch[4])


## Packs sync-ID-tagged AI into 5 PackedArrays:
## [ids, positions, rotations, speeds_strafes, packed].
## packed = state(0..7) | flags(8..23) | health(24..31).
## speeds_strafes = (speedI8 + 128) | ((strafeI8 + 128) << 8) per AI.
func pack_ai_batch(agentsNode: Node) -> Array:
    var _pt: int = _Perf.start()
    var ids: PackedInt32Array = []
    var positions: PackedVector3Array = []
    var rotations: PackedFloat32Array = []
    var speedsStrafes: PackedInt32Array = []
    var packed: PackedInt32Array = []

    for child: Node in agentsNode.get_children():
        if !child.has_meta(&"ai_sync_id"):
            continue
        ids.append(child.get_meta(&"ai_sync_id"))
        positions.append(child.global_position)
        rotations.append(child.global_rotation.y)

        # Quantize speed (0..3) + strafe (-1..1) to int8 each, pack into int16.
        var speedI: int = clampi(roundi(child.movementSpeed * 42.0), 0, 255)
        var strafeRaw: float = 0.0
        if child.get(&"north") == true:
            strafeRaw = 1.0
        elif child.get(&"south") == true:
            strafeRaw = -1.0
        var strafeI: int = clampi(roundi(strafeRaw * 127.0) + 128, 0, 255)
        speedsStrafes.append(speedI | (strafeI << 8))

        var state: int = int(child.currentState) & 0xFF
        var health: int = clampi(roundi(child.health), 0, 255)
        var f: int = 0
        if child.dead:
            f |= AIFlag.DEAD
        if child.get(&"impact") == true:
            f |= AIFlag.IMPACT
        if child.get(&"weapon") != null:
            var wData: Variant = child.get(&"weaponData")
            if wData != null && wData.get(&"weaponType") == "Pistol":
                f |= AIFlag.PISTOL
        packed.append(state | ((f & 0xFFFF) << 8) | ((health & 0xFF) << 24))

    _Perf.stop("pack_ai_batch", _pt)
    if ids.is_empty():
        return []
    return [ids, positions, rotations, speedsStrafes, packed]

# ---------- Client Receive ----------


## Receives batch AI state from host. Unreliable, 10Hz. Packed format:
## packed = state | (flags << 8) | (health << 24).
## speedsStrafes = (speedI8) | (strafeI8 << 8), both biased +128.
@rpc("authority", "call_remote", "unreliable")
func receive_ai_batch(
    ids: PackedInt32Array,
    positions: PackedVector3Array,
    rotations: PackedFloat32Array,
    speedsStrafes: PackedInt32Array,
    packed: PackedInt32Array,
) -> void:
    var _pt: int = _Perf.start()
    if Engine.get_physics_frames() % 600 == 0:
        _log("receive_ai_batch: %d ids, slotCount=%d" % [ids.size(), slotCount])
    var now: float = Time.get_ticks_msec() / 1000.0
    for i: int in ids.size():
        var idx: int = ids[i]
        if idx < 0 || idx >= slotCount:
            continue
        var p: int = packed[i]
        var ss: int = speedsStrafes[i]
        var buf: AIBuffer = aiBuffers[idx]
        buf.push_fields(
            now, positions[i], rotations[i],
            p & 0xFF,
            float(ss & 0xFF) / 42.0,
            (float((ss >> 8) & 0xFF) - 128.0) / 127.0,
            (p >> 24) & 0xFF,
            (p >> 8) & 0xFFFF,
        )
    _Perf.stop("receive_ai_batch", _pt)

# ---------- Client Interpolation ----------


## Reusable scratch snapshot for interpolation — avoids allocating a RefCounted per AI per tick.
var _interpSnap: AISnapshot = AISnapshot.new(0.0, Vector3.ZERO, 0.0, 0, 0.0, 0.0, 0, 0)


func _client_interpolate() -> void:
    if Engine.get_physics_frames() % 600 == 0:
        _log_interp_fill_stats()

    var renderTime: float = Time.get_ticks_msec() / 1000.0 - INTERP_DELAY
    var buf: AIBuffer = null
    var node: Node = null
    var count: int = 0

    for idx: int in slotCount:
        buf = aiBuffers[idx]
        count = buf.count
        if count == 0:
            continue
        node = aiNodes[idx]
        if !is_instance_valid(node):
            continue

        if activeOnClient[idx] == 0:
            _activate_on_client(idx, node)

        if count < 2:
            _apply_snapshot(idx, node, buf.get_at(0))
            continue

        _apply_interpolated(idx, node, buf, count, renderTime)


## Diagnostic: counts how many slots have at least one buffered snapshot.
## Logged every 600 physics frames (~5s at 120Hz) to catch stuck buffers.
func _log_interp_fill_stats() -> void:
    var filledSlots: int = 0
    for idx: int in slotCount:
        if aiBuffers[idx].count > 0:
            filledSlots += 1
    _log("_client_interpolate: slotCount=%d filledBuffers=%d" % [slotCount, filledSlots])


## Picks bracketing snapshots around renderTime, computes the lerp factor,
## writes into the reusable [member _interpSnap] scratch, and applies it.
func _apply_interpolated(idx: int, node: Node, buf: AIBuffer, count: int, renderTime: float) -> void:
    var _pt: int = _Perf.start()
    var from: AISnapshot = buf.newest()
    var to: AISnapshot = from
    for j: int in range(1, count):
        var candidate: AISnapshot = buf.get_at(j)
        if candidate.timestamp >= renderTime:
            from = buf.get_at(j - 1)
            to = candidate
            break

    var timeDiff: float = to.timestamp - from.timestamp
    var t: float = 0.0
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
    _apply_snapshot(idx, node, _interpSnap)
    _Perf.stop("apply_interpolated", _pt)


## Applies a snapshot to an AI node on the client: position, rotation, animation.
## Animator condition + blend writes are skipped when state + speed match the
## previous tick's apply for this idx — host broadcasts at 10Hz, client interp
## at 60Hz, so most ticks reapply identical values.
func _apply_snapshot(idx: int, node: Node, snap: AISnapshot) -> void:
    var _pt: int = _Perf.start()
    if (snap.flags & AIFlag.DEAD) != 0:
        _Perf.stop("apply_snapshot", _pt)
        return
    node.global_position = snap.position
    node.global_rotation.y = snap.rotation_y

    var animator: AnimationTree = node.get(&"animator")
    if !is_instance_valid(animator):
        return
    if !animator.active:
        animator.active = true

    var isPistol: bool = (snap.flags & AIFlag.PISTOL) != 0
    # Pack state + isPistol into a single int for the cache compare (state ≤
    # 256, pistol bit 9). Lets us short-circuit when both are unchanged.
    var stateKey: int = (snap.state & 0xFF) | (int(isPistol) << 8)
    if _lastAppliedState[idx] != stateKey:
        _lastAppliedState[idx] = stateKey
        animator[COND_RIFLE_MOVEMENT] = false
        animator[COND_RIFLE_COMBAT] = false
        animator[COND_RIFLE_HUNT] = false
        animator[COND_RIFLE_DEFEND] = false
        animator[COND_RIFLE_GUARD] = false
        animator[COND_RIFLE_GROUP] = false
        animator[COND_PISTOL_MOVEMENT] = false
        animator[COND_PISTOL_COMBAT] = false
        animator[COND_PISTOL_HUNT] = false
        animator[COND_PISTOL_DEFEND] = false
        animator[COND_PISTOL_GUARD] = false
        animator[COND_PISTOL_GROUP] = false
        animator[COND_PISTOL] = isPistol
        animator[COND_RIFLE] = !isPistol
        if IS_MOVEMENT[snap.state] == 1:
            animator[COND_RIFLE_MOVEMENT] = true
            animator[COND_PISTOL_MOVEMENT] = true
        elif snap.state == AIState.COMBAT:
            animator[COND_RIFLE_COMBAT] = true
            animator[COND_PISTOL_COMBAT] = true
        elif snap.state == AIState.HUNT:
            animator[COND_RIFLE_HUNT] = true
            animator[COND_PISTOL_HUNT] = true
        elif snap.state == AIState.DEFEND:
            animator[COND_RIFLE_DEFEND] = true
            animator[COND_PISTOL_DEFEND] = true
        elif IS_GUARD[snap.state] == 1:
            animator[COND_RIFLE_GUARD] = true
            animator[COND_PISTOL_GUARD] = true
        else:
            animator[COND_RIFLE_GROUP] = true
            animator[COND_PISTOL_GROUP] = true

    if absf(_lastAppliedSpeed[idx] - snap.move_speed) > SPEED_EPSILON:
        _lastAppliedSpeed[idx] = snap.move_speed
        if isPistol:
            animator[BLEND_PISTOL_MOVE] = snap.move_speed
            animator[BLEND_PISTOL_COMBAT] = snap.strafe
            animator[BLEND_PISTOL_HUNT] = snap.move_speed
        else:
            animator[BLEND_RIFLE_MOVE] = snap.move_speed
            animator[BLEND_RIFLE_COMBAT] = snap.strafe
            animator[BLEND_RIFLE_HUNT] = snap.move_speed

    _Perf.stop("apply_snapshot", _pt)


## Activates an AI node on the client for visual display.
## Reparents from pool to Agents, shows it, enables animator.
func _activate_on_client(idx: int, node: Node) -> void:
    activeOnClient[idx] = 1
    if !is_instance_valid(_agentsNode):
        if _get_spawner() == null || !is_instance_valid(_agentsNode):
            return
    if node.get_parent() != _agentsNode:
        node.reparent(_agentsNode)
    node.show()
    # Keep AI paused on client — we drive it via snapshots, not AI logic
    node.set(&"pause", true)
    node.set(&"sensorActive", false)
    # Activate animator immediately so bones leave T-pose before any snapshot
    # arrives. If the AI dies before the first _apply_snapshot tick (e.g. one-shot
    # kill on spawn), Death() ragdolls from the rest pose otherwise.
    var animator: AnimationTree = node.get(&"animator")
    if is_instance_valid(animator):
        animator.active = true

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
    if node.get(&"dead") == true:
        return
    if node.has_method(&"Death"):
        node.Death(direction, force)


## Host broadcasts that an AI fired its weapon.
func broadcast_ai_fire(syncId: int) -> void:
    _log("broadcast_ai_fire: syncId=%d" % syncId)
    receive_ai_fire.rpc(syncId)


## Client receives fire event — plays audio, muzzle VFX, and near-miss sounds.
@rpc("authority", "call_remote", "unreliable")
func receive_ai_fire(syncId: int) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    if node.has_method(&"PlayFire"):
        node.PlayFire()
    if node.has_method(&"PlayTail"):
        node.PlayTail()
    if node.has_method(&"MuzzleVFX"):
        node.MuzzleVFX()
    # Near-miss cosmetic — only fire if far enough that bullet arrival would lag audio.
    if !is_instance_valid(_controller):
        return
    if node.global_position.distance_to(_controller.global_position) > 50.0:
        _play_delayed_near_miss.call_deferred(node)


func _play_delayed_near_miss(node: Node) -> void:
    if !is_instance_valid(node):
        return
    await node.get_tree().create_timer(0.1, false).timeout
    if !is_instance_valid(node):
        return
    # Approximation of vanilla: vanilla picks crack-on-hit vs flyby-on-miss
    # deterministically from raycast result. We don't replicate the raycast to
    # clients, so pick one of the two per event.
    if randi_range(0, 1) == 0:
        if node.has_method(&"PlayCrack"):
            node.PlayCrack()
    else:
        if node.has_method(&"PlayFlyby"):
            node.PlayFlyby()


## Host broadcasts AI voice/damage sounds to clients.
func broadcast_ai_voice(syncId: int, voiceType: int) -> void:
    receive_ai_voice.rpc(syncId, voiceType)


@rpc("authority", "call_remote", "unreliable")
func receive_ai_voice(syncId: int, voiceType: int) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    match voiceType:
        VoiceType.IDLE:
            if node.has_method(&"PlayIdle"):
                node.PlayIdle()
        VoiceType.COMBAT:
            if node.has_method(&"PlayCombat"):
                node.PlayCombat()
        VoiceType.DAMAGE:
            if node.has_method(&"PlayDamage"):
                node.PlayDamage()


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
    if node.get(&"dead") == true:
        return
    if node.has_method(&"WeaponDamage"):
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
    if is_instance_valid(_character) && _character.has_method(&"WeaponDamage"):
        _character.WeaponDamage(damage, penetration)


## Sends explosion damage to a specific remote peer. Host only.
func send_explosion_damage_to_peer(peerId: int) -> void:
    receive_explosion_damage.rpc_id(peerId)


## Client receives explosion damage — applies to local player's Character node.
@rpc("authority", "call_remote", "reliable")
func receive_explosion_damage() -> void:
    if is_instance_valid(_character) && _character.has_method(&"ExplosionDamage"):
        _character.ExplosionDamage()

# ---------- Full State (Late Join) ----------


## Sends all active AI to a specific peer. Called by host on peer join.
func send_full_state(peerId: int) -> void:
    if !_cm.isHost:
        return
    if !is_instance_valid(_agentsNode):
        if _get_spawner() == null:
            _log("send_full_state: no spawner found")
            return
        if !is_instance_valid(_agentsNode):
            _log("send_full_state: no Agents node")
            return
    var sentCount: int = 0
    for child: Node in _agentsNode.get_children():
        if !child.has_meta(&"ai_sync_id"):
            continue
        if child.get(&"dead") == true:
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
    if is_instance_valid(_spawner):
        return _spawner
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return null
    _spawner = scene.get_node_or_null(^"AI")
    _agentsNode = _spawner.get_node_or_null(^"Agents") if is_instance_valid(_spawner) else null
    return _spawner


func _log(msg: String) -> void:
    if is_instance_valid(_cm):
        _cm._log("[AIState] %s" % msg)
    else:
        print("[AIState] %s" % msg)
