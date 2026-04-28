## Hook callbacks for RocketHelicopter.gd — host runs physics + collision; client lerps.
## Replaces patches/rocket_helicopter_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 18.0
const ROCKET_MAX_RANGE: float = 1000.0

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}
var _exploded: Dictionary[Node, bool] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("rockethelicopter-_physics_process", _on_phys)


func _on_phys(delta: float) -> void:
    var r: Node3D = _lib._caller as Node3D
    if r == null:
        return
    if !CoopManager.is_session_active():
        return
    _lib.skip_super()
    if CoopManager.isHost:
        _host_tick(r, delta)
        return
    _apply_host_snapshot(r, delta)


func _host_tick(r: Node3D, delta: float) -> void:
    if _exploded.get(r, false):
        return
    r.phase += delta
    r.rotate_y(deg_to_rad(sin(r.phase * r.horizontalFrequency) * r.deviation * delta))
    r.rotate_x(deg_to_rad(sin(r.phase * r.verticalFrequency + r.verticalOffset) * r.deviation * delta))
    r.global_position += r.transform.basis.z * r.speed * delta
    if r.ray.is_colliding():
        _coop_explode(r)
        return
    if r.global_position.distance_to(Vector3.ZERO) > ROCKET_MAX_RANGE:
        _coop_cleanup(r)


func _coop_explode(r: Node3D) -> void:
    if _exploded.get(r, false):
        return
    _exploded[r] = true
    var pos: Vector3 = r.global_position
    CoopManager.worldState.broadcast_rocket_explode.rpc(pos)
    var packed: PackedScene = load("res://Effects/Explosion.tscn") as PackedScene
    if packed != null:
        var instance: Node = packed.instantiate()
        r.get_tree().get_root().add_child(instance)
        if instance is Node3D:
            (instance as Node3D).global_position = pos
        if "size" in instance:
            instance.size = 20.0
        if instance.has_method(&"Explode"):
            instance.Explode()
    r.queue_free()


func _coop_cleanup(r: Node3D) -> void:
    if _exploded.get(r, false):
        return
    _exploded[r] = true
    CoopManager.worldState.broadcast_rocket_cleanup.rpc(r.global_position)
    r.queue_free()


func _apply_host_snapshot(r: Node3D, delta: float) -> void:
    var path: String = _relPaths.get(r, "")
    if path.is_empty():
        var scene: Node = r.get_tree().current_scene
        if is_instance_valid(scene):
            path = String(scene.get_path_to(r))
            _relPaths[r] = path
    if path.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(path)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    r.global_transform.origin = r.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    r.global_transform.basis = r.global_transform.basis.slerp(targetBasis, blend)
