## Patch for CASA.gd — host authoritative airdrop plane; clients lerp pose +
## run parachute cosmetic locally.
extends "res://Scripts/CASA.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null
var _relPath: String = ""
var _lastBroadcastDropped: bool = false
var _lastBroadcastReleased: bool = false
const LERP_SPEED: float = 8.0
## Match vehicle_state cadence: 120Hz / 12 = 10Hz.
const AIRDROP_SEND_EVERY_N_TICKS: int = 12


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func _ready() -> void:
    super._ready()
    if _ensure_cm() && _cm.is_session_active() && !_cm.isHost:
        if is_instance_valid(airdrop):
            airdrop.freeze = true
            airdrop.sleeping = true
            # Decouple airdrop transform from the plane so client-side lerp of
            # the plane (via vehicle_state snapshot) doesn't drag the crate.
            airdrop.set_as_top_level(true)


func _physics_process(delta: float) -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super._physics_process(delta)
        if _cm != null && _cm.is_session_active() && _cm.isHost:
            _broadcast_drop_edges()
            _broadcast_airdrop_pose()
        return
    # Client: plane pose from snapshot, propellers + parachute locally.
    leftPropeller.rotation.z += delta * 20.0
    rightPropeller.rotation.z += delta * 20.0
    Parachute(delta)
    _apply_host_snapshot(delta)
    _apply_airdrop_snapshot(delta)


func _broadcast_drop_edges() -> void:
    if dropped != _lastBroadcastDropped || released != _lastBroadcastReleased:
        _lastBroadcastDropped = dropped
        _lastBroadcastReleased = released
        _cm.worldState.broadcast_airdrop_state.rpc(_get_rel_path(), dropped, released)


## Host-only: 10Hz push of airdrop RigidBody3D world transform under the key
## "airdrop:<planePath>" — clients apply it via _apply_airdrop_snapshot.
func _broadcast_airdrop_pose() -> void:
    if !is_instance_valid(airdrop) || !airdrop.is_inside_tree():
        return
    if Engine.get_physics_frames() % AIRDROP_SEND_EVERY_N_TICKS != 0:
        return
    var relPath: String = _get_rel_path()
    if relPath.is_empty():
        return
    var a: Node3D = airdrop as Node3D
    var quat: Quaternion = a.global_transform.basis.get_rotation_quaternion()
    _cm.vehicleState.sync_vehicle_snapshot.rpc("airdrop:" + relPath, a.global_transform.origin, quat, 0.0, Engine.get_physics_frames())


func _get_rel_path() -> String:
    if _relPath.is_empty():
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            _relPath = String(scene.get_path_to(self))
    return _relPath


func _apply_host_snapshot(delta: float) -> void:
    var relPath: String = _get_rel_path()
    if relPath.is_empty():
        return
    var snap: Dictionary = _cm.vehicleState.get_snapshot(relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    global_transform.origin = global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    global_transform.basis = global_transform.basis.slerp(targetBasis, blend)


func _apply_airdrop_snapshot(delta: float) -> void:
    if !is_instance_valid(airdrop):
        return
    var relPath: String = _get_rel_path()
    if relPath.is_empty():
        return
    var snap: Dictionary = _cm.vehicleState.get_snapshot("airdrop:" + relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    airdrop.global_transform.origin = airdrop.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    airdrop.global_transform.basis = airdrop.global_transform.basis.slerp(targetBasis, blend)


func Collided(body: Node3D) -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.Collided(body)
        return
    if !_cm.isHost:
        return
    super.Collided(body)
    if is_instance_valid(airdrop):
        _cm.worldState.broadcast_airdrop_landing.rpc(airdrop.global_position)
