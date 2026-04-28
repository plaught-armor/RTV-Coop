## Hook callbacks for FishPool.gd — path-seeded RNG; all-peer distance check.
## Replaces patches/fish_pool_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("fishpool-_ready-pre", _on_ready_pre)
    lib.hook("fishpool-_physics_process", _on_phys)


func _on_ready_pre() -> void:
    var fp: Node3D = _lib._caller as Node3D
    if fp == null:
        return
    seed(hash(str(fp.get_path())))


func _on_phys(_delta: float) -> void:
    if Engine.get_physics_frames() % 100 != 0:
        return
    var fp: Node3D = _lib._caller as Node3D
    if fp == null:
        return
    _lib.skip_super()
    var minDist: float = _nearest_player_distance(fp)
    if !fp.active && minDist < 50.0:
        _set_children_active(fp, true)
        fp.active = true
    elif fp.active && minDist > 50.0:
        _set_children_active(fp, false)
        fp.active = false


func _set_children_active(fp: Node3D, enabled: bool) -> void:
    for child: Node in fp.get_children():
        if enabled:
            child.process_mode = Node.PROCESS_MODE_INHERIT
            if "active" in child:
                child.active = true
            child.show()
        else:
            child.hide()
            if "active" in child:
                child.active = false
            child.process_mode = Node.PROCESS_MODE_DISABLED


func _nearest_player_distance(fp: Node3D) -> float:
    var dist: float = fp.global_position.distance_to(fp.gameData.playerPosition)
    if !CoopManager.is_session_active():
        return dist
    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote):
            continue
        var d: float = fp.global_position.distance_to(remote.global_position)
        if d < dist:
            dist = d
    return dist
