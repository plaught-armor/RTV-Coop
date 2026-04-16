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
    set_layer_mask_value(1, false)
    if species.size() == 0:
        return
    # Seed from node path for deterministic fish spawns across peers.
    var pathHash: int = hash(str(get_path()))
    seed(pathHash)
    var poolBounds: AABB = mesh.get_aabb()
    var poolSize: Vector3 = poolBounds.size
    var poolPosition: Vector3 = global_position + poolBounds.position
    var fishAmount: int = randi_range(1, 10)
    for index: int in fishAmount:
        var randomFish: PackedScene = species[randi_range(0, species.size() - 1)]
        var randomPosition: Vector3 = Vector3(
            randf_range(0, poolSize.x),
            randf_range(0, poolSize.y),
            randf_range(0, poolSize.z)
        )
        var fish: Node3D = randomFish.instantiate()
        fish.name = "Fish"
        add_child(fish, true)
        fish.global_position = randomPosition + poolPosition


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
