## Hook callbacks for RocketGrad.gd — host runs physics; client lerps.
## Replaces patches/rocket_grad_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 18.0

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("rocketgrad-_process", _on_process)


func _on_process(delta: float) -> void:
    if Engine.is_editor_hint():
        return
    var r: Node3D = _lib._caller as Node3D
    if r == null:
        return
    if !CoopManager.is_session_active() || CoopManager.isHost:
        # Broadcast cleanup BEFORE vanilla — vanilla may queue_free; .rpc() on dying node undefined.
        if CoopManager != null && CoopManager.is_session_active() && CoopManager.isHost && r.launched && r.global_position.z > abs(r.tracking) + 100.0:
            CoopManager.worldState.broadcast_rocket_cleanup.rpc(r.global_position)
        return
    _lib.skip_super()
    _apply_host_snapshot(r, delta)


func _apply_host_snapshot(r: Node3D, delta: float) -> void:
    var path: String = _relPaths[r] if _relPaths.has(r) else ""
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
