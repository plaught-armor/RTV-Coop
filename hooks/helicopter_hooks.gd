## Hook callbacks for Helicopter.gd — host-authoritative; clients lerp snapshots.
## Replaces patches/helicopter_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 8.0

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("helicopter-_physics_process", _on_phys)
    lib.hook("helicopter-firerockets", _on_fire_rockets)


func _on_phys(delta: float) -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    var heli: Node3D = _lib._caller as Node3D
    if heli == null:
        return
    _lib.skip_super()
    heli.RotorBlades(delta)
    heli.DistanceClear()
    _apply_host_snapshot(heli, delta)


func _apply_host_snapshot(heli: Node3D, delta: float) -> void:
    var path: String = _relPaths.get(heli, "")
    if path.is_empty():
        var scene: Node = heli.get_tree().current_scene
        if is_instance_valid(scene):
            path = String(scene.get_path_to(heli))
            _relPaths[heli] = path
    if path.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(path)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    heli.global_transform.origin = heli.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    heli.global_transform.basis = heli.global_transform.basis.slerp(targetBasis, blend)


func _on_fire_rockets() -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    _lib.skip_super()
