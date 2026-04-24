## Host-auth AI replication at 10Hz; sync IDs are flat ints (A_Pool then B_Pool).
extends Node

const _AI_CONTAINER_PATHS: Array[NodePath] = [^"A_Pool", ^"B_Pool", ^"Agents"]
const _AI_POOL_PATHS: Array[NodePath] = [^"A_Pool", ^"B_Pool"]

var _controller: Node = null
var _character: Node = null
var _spawner: Node = null
var _agentsNode: Node = null



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



# 120Hz / 12 = 10Hz
const SEND_EVERY_N_TICKS: int = 12
const INTERP_DELAY: float = 0.15
const MAX_BUFFER_SIZE: int = 10

# MUST match enum State in Scripts/AI.gd:55 — verify after each game update.
enum AIState {
    IDLE, WANDER, GUARD, PATROL, HIDE, AMBUSH, COVER,
    DEFEND, SHIFT, COMBAT, HUNT, ATTACK, VANTAGE, RETURN,
}



# Indexed by AIState enum value; direct access avoids per-tick allocation.
var IS_MOVEMENT: PackedInt32Array
var IS_GUARD: PackedInt32Array


func _init() -> void:
    IS_MOVEMENT = _build_state_mask([
        AIState.WANDER, AIState.PATROL, AIState.HIDE, AIState.COVER,
        AIState.SHIFT, AIState.VANTAGE, AIState.RETURN, AIState.ATTACK,
    ])
    IS_GUARD = _build_state_mask([
        AIState.IDLE, AIState.GUARD, AIState.AMBUSH,
    ])


func _build_state_mask(states: Array[int]) -> PackedInt32Array:
    var mask: PackedInt32Array = []
    mask.resize(AIState.RETURN + 1)
    mask.fill(0)
    for s: int in states:
        mask[s] = 1
    return mask

# Animator paths as StringName to avoid per-tick String allocation.
const COND_PISTOL: StringName = &"parameters/conditions/Pistol"
const COND_RIFLE: StringName = &"parameters/conditions/Rifle"
# Per-state conditions live INSIDE Rifle/Pistol state machines (verified AI_Bandit.tscn:17873+).
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

enum AIFlag {
    DEAD = 1,
    IMPACT = 2,
    PISTOL = 4,
}


enum VoiceType {
    IDLE = 0,
    COMBAT = 1,
    DAMAGE = 2,
}


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


## Per-AI ring buffer: fixed-size, O(1) insert. Oldest at head; entries read slots[(head+i)%cap].
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


    func get_at(i: int) -> AISnapshot:
        return slots[(head + i) % capacity]


    func newest() -> AISnapshot:
        return slots[(head + count - 1) % capacity]


var slotCount: int = 0
# Flat arrays indexed by sync ID (0..slotCount-1); no hashing.
var aiNodes: Array[Node] = []
var aiBuffers: Array[AIBuffer] = []
# 0 = inactive on client, 1 = active (reparented to Agents).
var activeOnClient: PackedInt32Array = []
# Buffers receive_ai_activate calls that land before register_spawner_pools runs.
var pendingActivations: Array[Dictionary] = []


## Falls back to deterministic sync-ID assignment if spawner _ready ran super (no manager yet).
func register_spawner_pools(spawner: Node) -> void:
    _spawner = spawner
    _agentsNode = spawner.get_node_or_null(^"Agents") if is_instance_valid(spawner) else null

    var scanResult: Dictionary = _collect_tagged_ai_nodes(spawner)
    var allNodes: Array[Node] = scanResult.nodes
    var maxId: int = scanResult.maxId

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


func _collect_tagged_ai_nodes(spawner: Node) -> Dictionary:
    var out: Array[Node] = []
    var maxId: int = -1
    for container_name: NodePath in _AI_CONTAINER_PATHS:
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


# Cache of last-applied state + speed; skips redundant animator writes (most 60Hz ticks repeat).
var _lastAppliedState: PackedInt32Array = []
var _lastAppliedSpeed: PackedFloat32Array = []
const SPEED_EPSILON: float = 0.01


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


func _populate_slot_arrays(allNodes: Array[Node]) -> int:
    var activeCount: int = 0
    for child: Node in allNodes:
        var idx: int = child.get_meta(&"ai_sync_id")
        aiNodes[idx] = child
        if _agentsNode != null && child.get_parent() == _agentsNode:
            activeOnClient[idx] = 1
            activeCount += 1
    return activeCount


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

## Pools only: Agents children already spawned get tagged too but counts diverge host/client.
func _assign_sync_ids_from_spawner(spawner: Node) -> Array[Node]:
    var allNodes: Array[Node] = []
    var idx: int = 0
    for container_name: NodePath in _AI_POOL_PATHS:
        var container: Node = spawner.get_node_or_null(container_name)
        if container == null:
            continue
        for child: Node in container.get_children():
            child.set_meta(&"ai_sync_id", idx)
            allNodes.append(child)
            idx += 1
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


func _physics_process(_delta: float) -> void:
    CoopManager.perf.tick()
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return

    if CoopManager.isHost:
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
    # Same-map peers only: off-map clients get AI via headless_map; overlap corrupts indexing.
    var localPid: int = CoopManager.localPeerId
    for peerId: int in CoopManager.peerGodotIds:
        if peerId == -1 || peerId == localPid:
            continue
        if !CoopManager.is_peer_on_same_map(peerId):
            continue
        receive_ai_batch.rpc_id(peerId, batch[0], batch[1], batch[2], batch[3], batch[4])


# Returns [ids, positions, rotations, speeds_strafes, packed].
# packed = state(0..7) | flags(8..23) | health(24..31). speeds_strafes = speedI8 | (strafeI8<<8).
func pack_ai_batch(agentsNode: Node) -> Array:
    var _pt: int = CoopManager.perf.start()
    var ids: PackedInt32Array = []
    var positions: PackedVector3Array = []
    var rotations: PackedFloat32Array = []
    var speedsStrafes: PackedInt32Array = []
    var packed: PackedInt32Array = []

    for child: Node in agentsNode.get_children():
        if !child.has_meta(&"ai_sync_id"):
            continue
        # Children reparented mid-transition throw "Node not in tree" on global_transform read.
        if !child.is_inside_tree():
            continue
        ids.append(child.get_meta(&"ai_sync_id"))
        positions.append(child.global_position)
        rotations.append(child.global_rotation.y)

        # Quantize speed + strafe to int8 each, pack into int16.
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

    CoopManager.perf.stop("pack_ai_batch", _pt)
    if ids.is_empty():
        return []
    return [ids, positions, rotations, speedsStrafes, packed]

@rpc("authority", "call_remote", "unreliable")
func receive_ai_batch(
    ids: PackedInt32Array,
    positions: PackedVector3Array,
    rotations: PackedFloat32Array,
    speedsStrafes: PackedInt32Array,
    packed: PackedInt32Array,
) -> void:
    var _pt: int = CoopManager.perf.start()
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
    CoopManager.perf.stop("receive_ai_batch", _pt)

## Reusable scratch to avoid RefCounted alloc per AI per tick.
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


func _log_interp_fill_stats() -> void:
    var filledSlots: int = 0
    for idx: int in slotCount:
        if aiBuffers[idx].count > 0:
            filledSlots += 1
    _log("_client_interpolate: slotCount=%d filledBuffers=%d" % [slotCount, filledSlots])


func _apply_interpolated(idx: int, node: Node, buf: AIBuffer, count: int, renderTime: float) -> void:
    var _pt: int = CoopManager.perf.start()
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

    _interpSnap.timestamp = renderTime
    _interpSnap.position = from.position.lerp(to.position, t)
    _interpSnap.rotation_y = lerp_angle(from.rotation_y, to.rotation_y, t)
    _interpSnap.state = to.state
    _interpSnap.move_speed = lerpf(from.move_speed, to.move_speed, t)
    _interpSnap.strafe = lerpf(from.strafe, to.strafe, t)
    _interpSnap.health = to.health
    _interpSnap.flags = to.flags
    _apply_snapshot(idx, node, _interpSnap)
    CoopManager.perf.stop("apply_interpolated", _pt)


## Skips animator writes when state + speed match last apply (most 60Hz ticks repeat).
func _apply_snapshot(idx: int, node: Node, snap: AISnapshot) -> void:
    var _pt: int = CoopManager.perf.start()
    if (snap.flags & AIFlag.DEAD) != 0:
        CoopManager.perf.stop("apply_snapshot", _pt)
        return
    node.global_position = snap.position
    node.global_rotation.y = snap.rotation_y

    var animator: AnimationTree = node.get(&"animator")
    if !is_instance_valid(animator):
        return
    if !animator.active:
        animator.active = true

    var isPistol: bool = (snap.flags & AIFlag.PISTOL) != 0
    # Pack state + pistol bit into one int so cache compare short-circuits when unchanged.
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

    CoopManager.perf.stop("apply_snapshot", _pt)


func _activate_on_client(idx: int, node: Node) -> void:
    activeOnClient[idx] = 1
    if !is_instance_valid(_agentsNode):
        if _get_spawner() == null || !is_instance_valid(_agentsNode):
            return
    if node.get_parent() != _agentsNode:
        node.reparent(_agentsNode)
    node.show()
    # Snapshots drive on client; keep AI logic paused.
    node.set(&"pause", true)
    node.set(&"sensorActive", false)
    # Enable animator eagerly so Death() before first snapshot doesn't ragdoll from T-pose.
    var animator: AnimationTree = node.get(&"animator")
    if is_instance_valid(animator):
        animator.active = true


func broadcast_ai_activate(syncId: int, pos: Vector3, rotY: float, stateIdx: int) -> void:
    _log("broadcast_ai_activate: syncId=%d pos=%s state=%d" % [syncId, str(pos), stateIdx])
    receive_ai_activate.rpc(syncId, pos, rotY, stateIdx)


## Buffers to pendingActivations if register_spawner_pools hasn't populated aiNodes yet.
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


func broadcast_ai_death(syncId: int, direction: Vector3, force: float) -> void:
    _log("broadcast_ai_death: syncId=%d" % syncId)
    receive_ai_death.rpc(syncId, direction, force)


## Guards against double-death when batch DEAD flag arrives alongside.
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


func broadcast_ai_fire(syncId: int) -> void:
    _log("broadcast_ai_fire: syncId=%d" % syncId)
    receive_ai_fire.rpc(syncId)


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
    # Near-miss audio only past ~50m where bullet arrival outpaces source audio.
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
    # Vanilla picks crack vs flyby from raycast; we don't replicate it, so random.
    if randi_range(0, 1) == 0:
        if node.has_method(&"PlayCrack"):
            node.PlayCrack()
    else:
        if node.has_method(&"PlayFlyby"):
            node.PlayFlyby()


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


const HITBOX_ALLOWLIST: Array[String] = ["Head", "Torso", "Leg_L", "Leg_R"]
const MAX_CLIENT_DAMAGE: float = 500.0


@rpc("any_peer", "call_remote", "reliable")
func request_ai_damage_from_client(syncId: int, hitbox: String, damage: float) -> void:
    if !CoopManager.isHost:
        return
    if syncId < 0 || syncId >= slotCount:
        return
    if !HITBOX_ALLOWLIST.has(hitbox):
        return
    if damage <= 0.0 || damage > MAX_CLIENT_DAMAGE:
        return
    var node: Node = aiNodes[syncId]
    if !is_instance_valid(node):
        return
    if node.get(&"dead") == true:
        return
    if node.has_method(&"WeaponDamage"):
        # Host calls super WeaponDamage; patched version would re-route back to client.
        node.WeaponDamage(hitbox, damage)


func send_ai_damage_to_peer(peerId: int, damage: float, penetration: int) -> void:
    receive_ai_damage.rpc_id(peerId, damage, penetration)


@rpc("authority", "call_remote", "reliable")
func receive_ai_damage(damage: float, penetration: int) -> void:
    if is_instance_valid(_character) && _character.has_method(&"WeaponDamage"):
        _character.WeaponDamage(damage, penetration)


func send_explosion_damage_to_peer(peerId: int) -> void:
    receive_explosion_damage.rpc_id(peerId)


@rpc("authority", "call_remote", "reliable")
func receive_explosion_damage() -> void:
    if is_instance_valid(_character) && _character.has_method(&"ExplosionDamage"):
        _character.ExplosionDamage()


func send_full_state(peerId: int) -> void:
    if !CoopManager.isHost:
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
        if !child.is_inside_tree():
            continue
        if child.get(&"dead") == true:
            continue
        var idx: int = child.get_meta(&"ai_sync_id")
        receive_ai_activate.rpc_id(peerId, idx, child.global_position, child.global_rotation.y, child.currentState)
        sentCount += 1
    _log("send_full_state: sent %d active AI to peer %d" % [sentCount, peerId])

func clear() -> void:
    _log("clear: resetting (was slotCount=%d)" % slotCount)
    slotCount = 0
    aiBuffers.clear()
    aiNodes.clear()
    activeOnClient.resize(0)
    pendingActivations.clear()


func untrack(syncId: int) -> void:
    if syncId < 0 || syncId >= slotCount:
        return
    aiNodes[syncId] = null
    aiBuffers[syncId] = AIBuffer.new()
    activeOnClient[syncId] = 0

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
    if is_instance_valid(CoopManager):
        CoopManager._log("[AIState] %s" % msg)
    else:
        print("[AIState] %s" % msg)
