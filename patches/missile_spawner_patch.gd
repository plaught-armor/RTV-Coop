## Patch for MissileSpawner.gd — host drives launch, clients spawn identical
## missile pool via broadcast_missile_prepare/launch so indices align.
@tool
extends "res://Scripts/MissileSpawner.gd"

var _cm: Node = null


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    if Engine.is_editor_hint():
        return false
    var tree: SceneTree = get_tree()
    if tree == null:
        return false
    var root: Node = tree.root
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func ExecuteLaunchMissiles(value: bool) -> void:
    if Engine.is_editor_hint() || !_ensure_cm() || !_cm.is_session_active():
        super.ExecuteLaunchMissiles(value)
        return
    if !_cm.isHost:
        launchMissiles = false
        return
    _coop_host_launch()


func _coop_host_launch() -> void:
    var pool: Array = get_children().filter(
        func(n: Node) -> bool: return n.has_method(&"ExecuteLaunch"))
    var needsPrepare: bool = pool.is_empty()
    if needsPrepare:
        ExecutePrepareMissiles(true)
        pool = get_children().filter(
            func(n: Node) -> bool: return n.has_method(&"ExecuteLaunch"))

    var scene: Node = get_tree().current_scene
    var relPath: String = String(scene.get_path_to(self)) if is_instance_valid(scene) else ""
    if !relPath.is_empty() && needsPrepare:
        _cm.worldState.broadcast_missile_prepare.rpc(relPath)

    pool.shuffle()
    launched = true
    var total: int = pool.size()
    var fired: int = 0
    for element: Node in pool:
        await get_tree().create_timer(randf_range(0.0, launchDelay)).timeout
        if !is_instance_valid(self):
            return
        if !is_instance_valid(element):
            continue
        if element is Node3D:
            (element as Node3D).visible = true
        element.ExecuteLaunch(true)
        if !relPath.is_empty():
            _cm.worldState.broadcast_missile_launch.rpc(relPath, element.get_index())
        fired += 1
        if fired == total:
            launched = false
    launchMissiles = false
