## Patch for FishPool.gd — path-seeded RNG for deterministic spawns; all-peer distance check.
extends "res://Scripts/FishPool.gd"


var _cm: Node


func _ready() -> void:
    # Seed before super's randi/randf calls so all peers roll identical spawns.
    seed(hash(str(get_path())))
    super._ready()


# Full override (no super): base uses only local playerPosition; we need min across all peers.
func _physics_process(_delta: float) -> void:
    if Engine.get_physics_frames() % 100 != 0:
        return
    var minDist: float = _nearest_player_distance()
    if !active && minDist < 50.0:
        _set_children_active(true)
        active = true
    elif active && minDist > 50.0:
        _set_children_active(false)
        active = false


func _set_children_active(enabled: bool) -> void:
    for child: Node in get_children():
        if enabled:
            child.process_mode = Node.PROCESS_MODE_INHERIT
            child.active = true
            child.show()
        else:
            child.hide()
            child.active = false
            child.process_mode = Node.PROCESS_MODE_DISABLED


func _nearest_player_distance() -> float:
    var dist: float = global_position.distance_to(gameData.playerPosition)
    if !_ensure_cm() || !_cm.is_session_active():
        return dist
    for remote: Node3D in _cm.remoteNodes:
        if !is_instance_valid(remote):
            continue
        var d: float = global_position.distance_to(remote.global_position)
        if d < dist:
            dist = d
    return dist


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
