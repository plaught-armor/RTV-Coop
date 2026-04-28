## Hook callbacks for Police.gd — host-authoritative; clients freeze + lerp.
## Replaces patches/police_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 10.0

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}
# Per-instance state for cosmetic motion derivation on clients.
var _clientPrev: Dictionary[Node, Vector3] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("police-_ready-post", _on_ready_post)
    lib.hook("police-_physics_process", _on_phys)


func _on_ready_post() -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    var p: Node3D = _lib._caller as Node3D
    if p == null:
        return
    p.freeze = true
    _clientPrev[p] = p.global_position


func _on_phys(delta: float) -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    var p: Node3D = _lib._caller as Node3D
    if p == null:
        return
    _lib.skip_super()
    _apply_host_snapshot(p, delta)
    _run_client_cosmetics(p, delta)


func _apply_host_snapshot(p: Node3D, delta: float) -> void:
    var path: String = _relPaths.get(p, "")
    if path.is_empty():
        var scene: Node = p.get_tree().current_scene
        if is_instance_valid(scene):
            path = String(scene.get_path_to(p))
            _relPaths[p] = path
    if path.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(path)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    p.global_transform.origin = p.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    p.global_transform.basis = p.global_transform.basis.slerp(targetBasis, blend)


func _run_client_cosmetics(p: Node3D, delta: float) -> void:
    var prev: Vector3 = _clientPrev.get(p, p.global_position)
    var vel: Vector3 = (p.global_position - prev) / max(delta, 0.001)
    _clientPrev[p] = p.global_position
    var fwd: float = vel.dot(p.global_transform.basis.z)
    p.Tire_FL.rotation.y = lerp_angle(p.Tire_FL.rotation.y, 0.0, delta * p.steerSmoothness)
    p.Tire_FR.rotation.y = lerp_angle(p.Tire_FR.rotation.y, 0.0, delta * p.steerSmoothness)
    p.Tire_FL.rotation.x += fwd * delta
    p.Tire_FR.rotation.x += fwd * delta
    p.Tire_RL.rotation.x += fwd * delta
    p.Tire_RR.rotation.x += fwd * delta
    p.Suspension(delta)
    p.Wobble(delta)
    p.Audio(delta)
    if p.currentState == p.State.Boss:
        p.police.rotation.y += delta * 20.0
