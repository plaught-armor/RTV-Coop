## Co-op patch for FishPool.gd
##
## Two fixes:
## 1. Seeds fish spawn RNG from node path so all peers get identical fish
##    count, species, and positions. Without this, each peer rolls different
##    random values in _ready().
## 2. Distance check considers all players (host + remotes) so pools
##    activate when ANY player is within range, not just local player.
extends "res://Scripts/FishPool.gd"


var _cm: Node


func _ready() -> void:
    # Seed the global RNG from node path BEFORE super runs its randi_range
    # / randf_range calls. Every peer walks the same node tree + same path =
    # same hash = same seed = same fish count/species/positions. super keeps
    # owning the spawn logic so future base changes benefit.
    seed(hash(str(get_path())))
    super._ready()


## Full override (no super) — base only checks local gameData.playerPosition;
## we need the minimum across all peers so pools wake for any nearby player.
## If base adds new per-tick logic, port it here.
func _physics_process(_delta: float) -> void:
    if Engine.get_physics_frames() % 100 != 0:
        return
    _ensure_cm()
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


## Returns distance to nearest player (local + all remotes).
func _nearest_player_distance() -> float:
    var dist: float = global_position.distance_to(gameData.playerPosition)
    if _cm == null || !_cm.is_session_active():
        return dist
    for peerId: int in _cm.remoteNodes:
        var remote: Node3D = _cm.remoteNodes[peerId]
        if is_instance_valid(remote):
            var d: float = global_position.distance_to(remote.global_position)
            if d < dist:
                dist = d
    return dist


func _ensure_cm() -> void:
    if is_instance_valid(_cm):
        return
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return
