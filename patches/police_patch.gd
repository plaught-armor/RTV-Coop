## Patch for Police.gd — host authoritative; clients freeze and lerp snapshots.
extends "res://Scripts/Police.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null
var _relPath: String = ""
var _clientPrevPos: Vector3 = Vector3.ZERO
var _clientPrevReady: bool = false
const LERP_SPEED: float = 10.0


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func _ready() -> void:
    super._ready()
    if _ensure_cm() && _cm.is_session_active() && !_cm.isHost:
        freeze = true
        _clientPrevPos = global_position
        _clientPrevReady = true


func _physics_process(delta: float) -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super._physics_process(delta)
        return
    _apply_host_snapshot(delta)
    _run_client_cosmetics(delta)


func _apply_host_snapshot(delta: float) -> void:
    if _relPath.is_empty():
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            _relPath = String(scene.get_path_to(self))
    if _relPath.is_empty():
        return
    var snap: Dictionary = _cm.vehicleState.get_snapshot(_relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    global_transform.origin = global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    global_transform.basis = global_transform.basis.slerp(targetBasis, blend)


func _run_client_cosmetics(delta: float) -> void:
    var vel: Vector3 = Vector3.ZERO
    if _clientPrevReady:
        vel = (global_position - _clientPrevPos) / max(delta, 0.001)
    _clientPrevPos = global_position
    _clientPrevReady = true
    var fwd: float = vel.dot(global_transform.basis.z)
    Tire_FL.rotation.y = lerp_angle(Tire_FL.rotation.y, 0.0, delta * steerSmoothness)
    Tire_FR.rotation.y = lerp_angle(Tire_FR.rotation.y, 0.0, delta * steerSmoothness)
    Tire_FL.rotation.x += fwd * delta
    Tire_FR.rotation.x += fwd * delta
    Tire_RL.rotation.x += fwd * delta
    Tire_RR.rotation.x += fwd * delta
    Suspension(delta)
    Wobble(delta)
    Audio(delta)
    if currentState == State.Boss:
        police.rotation.y += delta * 20.0
