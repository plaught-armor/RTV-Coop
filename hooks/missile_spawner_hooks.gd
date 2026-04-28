## Hook callbacks for MissileSpawner.gd — host drives launch; client mirrors via RPC.
## Replaces patches/missile_spawner_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("missilespawner-executelaunchmissiles", _on_execute_launch)


func _on_execute_launch(value: bool) -> void:
    if Engine.is_editor_hint() || !CoopManager.is_session_active():
        return
    var s: Node3D = _lib._caller as Node3D
    if s == null:
        return
    _lib.skip_super()
    if !CoopManager.isHost:
        s.launchMissiles = false
        return
    _coop_host_launch(s, value)


func _has_execute_launch(n: Node) -> bool:
    return n.has_method(&"ExecuteLaunch")


func _coop_host_launch(s: Node, _value: bool) -> void:
    var pool: Array = s.get_children().filter(_has_execute_launch)
    var needsPrepare: bool = pool.is_empty()
    if needsPrepare:
        s.ExecutePrepareMissiles(true)
        pool = s.get_children().filter(_has_execute_launch)

    var scene: Node = s.get_tree().current_scene
    var relPath: String = String(scene.get_path_to(s)) if is_instance_valid(scene) else ""
    if !relPath.is_empty() && needsPrepare:
        CoopManager.worldState.broadcast_missile_prepare.rpc(relPath)

    pool.shuffle()
    s.launched = true
    var total: int = pool.size()
    var fired: int = 0
    for element: Node in pool:
        await s.get_tree().create_timer(randf_range(0.0, s.launchDelay)).timeout
        if !is_instance_valid(s) || !CoopManager.is_session_active():
            return
        if !is_instance_valid(element):
            continue
        if element is Node3D:
            (element as Node3D).visible = true
        element.ExecuteLaunch(true)
        if !relPath.is_empty() && is_instance_valid(CoopManager.worldState):
            var orderedPool: Array = s.get_children().filter(_has_execute_launch)
            var poolIdx: int = orderedPool.find(element)
            if poolIdx >= 0:
                CoopManager.worldState.broadcast_missile_launch.rpc(relPath, poolIdx)
        fired += 1
        if fired == total:
            s.launched = false
    s.launchMissiles = false
