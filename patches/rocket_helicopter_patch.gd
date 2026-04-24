## Patch for RocketHelicopter.gd — host runs physics + collision, broadcasts
## explosion; clients lerp snapshot.
extends "res://Scripts/RocketHelicopter.gd"

var _relPath: String = ""
var _exploded: bool = false
const LERP_SPEED: float = 18.0
const ROCKET_MAX_RANGE: float = 1000.0


func _physics_process(delta: float) -> void:
    if !CoopManager.is_session_active():
        super._physics_process(delta)
        return
    if CoopManager.isHost:
        _host_tick(delta)
        return
    _apply_host_snapshot(delta)


func _host_tick(delta: float) -> void:
    if _exploded:
        return
    phase += delta
    rotate_y(deg_to_rad(sin(phase * horizontalFrequency) * deviation * delta))
    rotate_x(deg_to_rad(sin(phase * verticalFrequency + verticalOffset) * deviation * delta))
    global_position += transform.basis.z * speed * delta
    if ray.is_colliding():
        _coop_explode()
        return
    if global_position.distance_to(Vector3.ZERO) > ROCKET_MAX_RANGE:
        _coop_cleanup()


func _coop_explode() -> void:
    if _exploded:
        return
    _exploded = true
    var pos: Vector3 = global_position
    CoopManager.worldState.broadcast_rocket_explode.rpc(pos)
    var packed: PackedScene = load("res://Effects/Explosion.tscn") as PackedScene
    if packed != null:
        var instance: Node = packed.instantiate()
        get_tree().get_root().add_child(instance)
        if instance is Node3D:
            (instance as Node3D).global_position = pos
        if "size" in instance:
            instance.size = 20.0
        if instance.has_method(&"Explode"):
            instance.Explode()
    queue_free()


func _coop_cleanup() -> void:
    if _exploded:
        return
    _exploded = true
    CoopManager.worldState.broadcast_rocket_cleanup.rpc(global_position)
    queue_free()


func _apply_host_snapshot(delta: float) -> void:
    if _relPath.is_empty():
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            _relPath = String(scene.get_path_to(self))
    if _relPath.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(_relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    global_transform.origin = global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    global_transform.basis = global_transform.basis.slerp(targetBasis, blend)
