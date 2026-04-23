## Patch for AISpawner.gd — host-auth spawning; clients build pools but suppress spawns.
extends "res://Scripts/AISpawner.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super._ready()
        return

    _log("_ready() co-op path (isHost=%s, zone=%d, active=%s)" % [str(_cm.isHost), zone, str(active)])

    GetPoints()
    HidePoints()

    if !active:
        _log("Spawner not active — skipping pools")
        return

    if zone == Zone.Area05:
        agent = bandit
    elif zone == Zone.BorderZone:
        agent = guard
    elif zone == Zone.Vostok:
        agent = military

    # CreatePools is a coroutine; must await before _assign_sync_ids or late spawns have no meta.
    await CreatePools()
    _log("Pools created: A_Pool=%d, B_Pool=%d" % [APool.get_child_count(), BPool.get_child_count()])

    # Tag sync IDs BEFORE spawns: reparent changes child counts, but meta persists.
    _assign_sync_ids()

    if is_instance_valid(_cm.aiState):
        _cm.aiState.register_spawner_pools(self)

    if _cm.isHost:
        if initialGuard:
            _log("Initial spawn: Guard")
            super.SpawnGuard()
        if initialHider:
            if randi_range(0, 100) < 25:
                _log("Initial spawn: Hider")
                super.SpawnHider()
        _log("After initial spawns: A_Pool=%d, Agents=%d" % [APool.get_child_count(), agents.get_child_count()])
    else:
        _log("Client: skipping initial spawns")


## A_Pool gets 0..N-1, B_Pool gets N..N+M-1. Must run once before any spawns.
func _assign_sync_ids() -> void:
    var idx: int = 0
    for i: int in APool.get_child_count():
        APool.get_child(i).set_meta(&"ai_sync_id", idx)
        idx += 1
    for i: int in BPool.get_child_count():
        BPool.get_child(i).set_meta(&"ai_sync_id", idx)
        idx += 1
    _log("Assigned sync IDs: 0..%d (%d total)" % [idx - 1, idx])


## Host-auth wanderer spawn; filters points by distance to ALL players.
func SpawnWanderer() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.SpawnWanderer()
        return
    if !_cm.isHost:
        return

    if APool.get_child_count() == 0:
        _log("SpawnWanderer: APool empty")
        return

    var validPoints: Array[Node3D] = []
    for point: Node3D in spawns:
        if _min_player_distance(point.global_position) > spawnDistance:
            validPoints.append(point)

    if validPoints.is_empty():
        _log("SpawnWanderer: no valid points (dist > %d)" % spawnDistance)
        return

    var spawnPoint: Node3D = validPoints[randi_range(0, validPoints.size() - 1)]
    var newAgent: Node = APool.get_child(0)
    newAgent.reparent(agents)
    newAgent.global_transform = spawnPoint.global_transform
    newAgent.currentPoint = spawnPoint
    newAgent.ActivateWanderer()
    activeAgents += 1
    _init_and_broadcast(newAgent)
    _log("SpawnWanderer: spawned (active=%d, pool=%d)" % [activeAgents, APool.get_child_count()])


func SpawnGuard() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.SpawnGuard()
        return
    if !_cm.isHost:
        return
    var prevCount: int = agents.get_child_count()
    super.SpawnGuard()
    _init_and_broadcast_if_new(prevCount)
    _log("SpawnGuard: agents=%d" % agents.get_child_count())


func SpawnHider() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.SpawnHider()
        return
    if !_cm.isHost:
        return
    var prevCount: int = agents.get_child_count()
    super.SpawnHider()
    _init_and_broadcast_if_new(prevCount)
    _log("SpawnHider: agents=%d" % agents.get_child_count())


func SpawnMinion(spawnPosition: Vector3) -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.SpawnMinion(spawnPosition)
        return
    if !_cm.isHost:
        return
    var prevCount: int = agents.get_child_count()
    super.SpawnMinion(spawnPosition)
    _init_and_broadcast_if_new(prevCount)
    _log("SpawnMinion: agents=%d" % agents.get_child_count())


func SpawnBoss(spawnPosition: Vector3) -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.SpawnBoss(spawnPosition)
        return
    if !_cm.isHost:
        return
    var prevCount: int = agents.get_child_count()
    super.SpawnBoss(spawnPosition)
    _init_and_broadcast_if_new(prevCount)
    _log("SpawnBoss: agents=%d" % agents.get_child_count())


func _init_and_broadcast_if_new(prevCount: int) -> void:
    if agents.get_child_count() <= prevCount:
        _log("_init_and_broadcast_if_new: no new agent (prev=%d, now=%d)" % [prevCount, agents.get_child_count()])
        return
    var newAgent: Node = agents.get_child(agents.get_child_count() - 1)
    _init_and_broadcast(newAgent)


func _init_and_broadcast(newAgent: Node) -> void:
    if !newAgent.has_meta(&"ai_sync_id"):
        _log("_init_and_broadcast: agent has no sync_id meta!")
        return
    newAgent._cm = _cm
    var syncId: int = newAgent.get_meta(&"ai_sync_id")
    var pos: Vector3 = newAgent.global_position
    var rotY: float = newAgent.global_rotation.y
    var stateIdx: int = newAgent.currentState
    _log("Broadcasting AI activate: syncId=%d pos=%s state=%d" % [syncId, str(pos), stateIdx])
    _cm.aiState.broadcast_ai_activate(syncId, pos, rotY, stateIdx)


func _min_player_distance(pos: Vector3) -> float:
    var minDist: float = pos.distance_to(gameData.playerPosition)
    for remote: Node3D in _cm.remoteNodes:
        if !is_instance_valid(remote):
            continue
        var dist: float = pos.distance_to(remote.global_position)
        if dist < minDist:
            minDist = dist
    return minDist


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func _log(msg: String) -> void:
    if is_instance_valid(_cm):
        _cm._log("[AISpawner] %s" % msg)
    else:
        print("[AISpawner] %s" % msg)
