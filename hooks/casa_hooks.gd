## Hook callbacks for CASA.gd — host airdrop plane; clients lerp + parachute cosmetic.
## Replaces patches/casa_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 8.0
## Match vehicle_state cadence: 120Hz / 12 = 10Hz.
const AIRDROP_SEND_EVERY_N_TICKS: int = 12

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}
var _lastBroadcastDropped: Dictionary[Node, bool] = {}
var _lastBroadcastReleased: Dictionary[Node, bool] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("casa-_ready-post", _on_ready_post)
    lib.hook("casa-_physics_process", _on_phys)
    lib.hook("casa-collided", _on_collided)


func _on_ready_post() -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    var c: Node = _lib._caller
    if c == null || !is_instance_valid(c.airdrop):
        return
    c.airdrop.freeze = true
    c.airdrop.sleeping = true
    c.airdrop.set_as_top_level(true)


func _on_phys(delta: float) -> void:
    var c: Node3D = _lib._caller as Node3D
    if c == null:
        return
    if !CoopManager.is_session_active() || CoopManager.isHost:
        if CoopManager != null && CoopManager.is_session_active() && CoopManager.isHost:
            _broadcast_drop_edges(c)
            _broadcast_airdrop_pose(c)
        return
    _lib.skip_super()
    c.leftPropeller.rotation.z += delta * 20.0
    c.rightPropeller.rotation.z += delta * 20.0
    c.Parachute(delta)
    _apply_host_snapshot(c, delta)
    _apply_airdrop_snapshot(c, delta)


func _broadcast_drop_edges(c: Node3D) -> void:
    var prevDrop: bool = _lastBroadcastDropped.get(c, false)
    var prevRel: bool = _lastBroadcastReleased.get(c, false)
    if c.dropped != prevDrop || c.released != prevRel:
        _lastBroadcastDropped[c] = c.dropped
        _lastBroadcastReleased[c] = c.released
        CoopManager.worldState.broadcast_airdrop_state.rpc(_get_rel_path(c), c.dropped, c.released)


func _broadcast_airdrop_pose(c: Node3D) -> void:
    if !is_instance_valid(c.airdrop) || !c.airdrop.is_inside_tree():
        return
    if Engine.get_physics_frames() % AIRDROP_SEND_EVERY_N_TICKS != 0:
        return
    var relPath: String = _get_rel_path(c)
    if relPath.is_empty():
        return
    var a: Node3D = c.airdrop as Node3D
    var quat: Quaternion = a.global_transform.basis.get_rotation_quaternion()
    CoopManager.vehicleState.sync_vehicle_snapshot.rpc("airdrop:" + relPath, a.global_transform.origin, quat, 0.0, Engine.get_physics_frames())


func _get_rel_path(c: Node3D) -> String:
    var path: String = _relPaths.get(c, "")
    if path.is_empty():
        var scene: Node = c.get_tree().current_scene
        if is_instance_valid(scene):
            path = String(scene.get_path_to(c))
            _relPaths[c] = path
    return path


func _apply_host_snapshot(c: Node3D, delta: float) -> void:
    var relPath: String = _get_rel_path(c)
    if relPath.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    c.global_transform.origin = c.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    c.global_transform.basis = c.global_transform.basis.slerp(targetBasis, blend)


func _apply_airdrop_snapshot(c: Node3D, delta: float) -> void:
    if !is_instance_valid(c.airdrop):
        return
    var relPath: String = _get_rel_path(c)
    if relPath.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot("airdrop:" + relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    c.airdrop.global_transform.origin = c.airdrop.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    c.airdrop.global_transform.basis = c.airdrop.global_transform.basis.slerp(targetBasis, blend)


func _on_collided(_body: Node3D) -> void:
    if !CoopManager.is_session_active():
        return
    if !CoopManager.isHost:
        _lib.skip_super()
        return
    var c: Node = _lib._caller
    if c != null && is_instance_valid(c.airdrop):
        CoopManager.worldState.broadcast_airdrop_landing.rpc(c.airdrop.global_position)
