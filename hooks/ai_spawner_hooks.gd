## Hook callbacks for AISpawner.gd — host-auth spawning; clients build pools but suppress spawns.
## Replaces patches/ai_spawner_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Zone enum (vanilla AISpawner.gd:13): 0=Area05, 1=BorderZone, 2=Vostok.
extends RefCounted


const ZONE_AREA05: int = 0
const ZONE_BORDER: int = 1
const ZONE_VOSTOK: int = 2

var _lib: Object = null
# Per-instance pre-spawn agent counts (pre-hook stash, post-hook compares).
var _prevCount: Dictionary[Node, int] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("aispawner-_ready", _on_ready)
    lib.hook("aispawner-spawnwanderer", _on_spawn_wanderer)
    # Void-arg spawns
    lib.hook("aispawner-spawnguard", _gate_void)
    lib.hook("aispawner-spawnguard-post", _post_void)
    lib.hook("aispawner-spawnhider", _gate_void)
    lib.hook("aispawner-spawnhider-post", _post_void)
    # Vector3-arg spawns
    lib.hook("aispawner-spawnminion", _gate_pos)
    lib.hook("aispawner-spawnminion-post", _post_pos)
    lib.hook("aispawner-spawnboss", _gate_pos)
    lib.hook("aispawner-spawnboss-post", _post_pos)


func _on_ready() -> void:
    var s: Node = _lib._caller
    if s == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla _ready runs

    _log("_ready() co-op path (isHost=%s, zone=%d, active=%s)" % [str(CoopManager.isHost), s.zone, str(s.active)])
    _lib.skip_super()

    var spawnMul: float = CoopManager.settings.get("ai_spawn_multiplier", 1.0)
    if spawnMul != 1.0:
        s.spawnLimit = maxi(0, roundi(float(s.spawnLimit) * spawnMul))
        s.spawnPool = maxi(1, roundi(float(s.spawnPool) * spawnMul))

    s.GetPoints()
    s.HidePoints()

    if !s.active:
        _log("Spawner not active — skipping pools")
        return

    if s.zone == ZONE_AREA05:
        s.agent = s.bandit
    elif s.zone == ZONE_BORDER:
        s.agent = s.guard
    elif s.zone == ZONE_VOSTOK:
        s.agent = s.military

    await s.CreatePools()
    _log("Pools created: A_Pool=%d, B_Pool=%d" % [s.APool.get_child_count(), s.BPool.get_child_count()])

    _assign_sync_ids(s)

    if is_instance_valid(CoopManager.aiState):
        CoopManager.aiState.register_spawner_pools(s)

    if CoopManager.isHost:
        if s.initialGuard:
            _log("Initial spawn: Guard")
            s.SpawnGuard()
        if s.initialHider:
            if randi_range(0, 100) < 25:
                _log("Initial spawn: Hider")
                s.SpawnHider()
        _log("After initial spawns: A_Pool=%d, Agents=%d" % [s.APool.get_child_count(), s.agents.get_child_count()])
    else:
        _log("Client: skipping initial spawns")


func _assign_sync_ids(s: Node) -> void:
    var idx: int = 0
    for i: int in s.APool.get_child_count():
        s.APool.get_child(i).set_meta(&"ai_sync_id", idx)
        idx += 1
    for i: int in s.BPool.get_child_count():
        s.BPool.get_child(i).set_meta(&"ai_sync_id", idx)
        idx += 1
    _log("Assigned sync IDs: 0..%d (%d total)" % [idx - 1, idx])


func _on_spawn_wanderer() -> void:
    if !CoopManager.is_session_active():
        return  # vanilla runs
    _lib.skip_super()
    if !CoopManager.isHost:
        return
    var s: Node = _lib._caller
    if s == null:
        return
    if s.APool.get_child_count() == 0:
        _log("SpawnWanderer: APool empty")
        return
    var validPoints: Array[Node3D] = []
    for point: Node3D in s.spawns:
        if _min_player_distance(s, point.global_position) > s.spawnDistance:
            validPoints.append(point)
    if validPoints.is_empty():
        _log("SpawnWanderer: no valid points (dist > %d)" % s.spawnDistance)
        return
    var spawnPoint: Node3D = validPoints[randi_range(0, validPoints.size() - 1)]
    var newAgent: Node = s.APool.get_child(0)
    newAgent.reparent(s.agents)
    newAgent.global_transform = spawnPoint.global_transform
    newAgent.currentPoint = spawnPoint
    newAgent.ActivateWanderer()
    s.activeAgents += 1
    _init_and_broadcast(newAgent)
    _log("SpawnWanderer: spawned (active=%d, pool=%d)" % [s.activeAgents, s.APool.get_child_count()])


func _gate_void() -> void:
    _gate_common()


func _gate_pos(_spawnPosition: Vector3) -> void:
    _gate_common()


func _gate_common() -> void:
    if !CoopManager.is_session_active():
        return  # vanilla runs
    if !CoopManager.isHost:
        _lib.skip_super()  # client: no spawn
        return
    var s: Node = _lib._caller
    if s != null:
        _prevCount[s] = s.agents.get_child_count()


func _post_void() -> void:
    _post_common()


func _post_pos(_spawnPosition: Vector3) -> void:
    _post_common()


func _post_common() -> void:
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    var s: Node = _lib._caller
    if s == null:
        return
    var prev: int = _prevCount.get(s, -1)
    _prevCount.erase(s)
    if prev < 0:
        return
    if s.agents.get_child_count() <= prev:
        _log("post-spawn: no new agent (prev=%d, now=%d)" % [prev, s.agents.get_child_count()])
        return
    var newAgent: Node = s.agents.get_child(s.agents.get_child_count() - 1)
    _init_and_broadcast(newAgent)


func _init_and_broadcast(newAgent: Node) -> void:
    if !newAgent.has_meta(&"ai_sync_id"):
        _log("_init_and_broadcast: agent has no sync_id meta!")
        return
    var syncId: int = newAgent.get_meta(&"ai_sync_id")
    var pos: Vector3 = newAgent.global_position
    var rotY: float = newAgent.global_rotation.y
    var stateIdx: int = newAgent.currentState
    _log("Broadcasting AI activate: syncId=%d pos=%s state=%d" % [syncId, str(pos), stateIdx])
    CoopManager.aiState.broadcast_ai_activate(syncId, pos, rotY, stateIdx)


func _min_player_distance(s: Node, pos: Vector3) -> float:
    var minDist: float = pos.distance_to(s.gameData.playerPosition)
    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote):
            continue
        var dist: float = pos.distance_to(remote.global_position)
        if dist < minDist:
            minDist = dist
    return minDist


func _log(msg: String) -> void:
    if is_instance_valid(CoopManager):
        CoopManager._log("[AISpawner] %s" % msg)
    else:
        print("[AISpawner] %s" % msg)
