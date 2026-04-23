## Patch for Helicopter.gd — host-authoritative; clients lerp snapshots from vehicle_state.gd.
extends "res://Scripts/Helicopter.gd"

var _cm: Node = null
var _relPath: String = ""
const LERP_SPEED: float = 8.0


# Lazy lookup: take_over_path replaces script before autoloads wire, preload returns null.
func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func _physics_process(delta: float) -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super._physics_process(delta)
        return
    RotorBlades(delta)
    DistanceClear()
    _apply_host_snapshot(delta)


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


func FireRockets() -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super.FireRockets()
        return
