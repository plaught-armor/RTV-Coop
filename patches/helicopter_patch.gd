## Patch for Helicopter.gd — host-authoritative; clients lerp snapshots from vehicle_state.gd.
extends "res://Scripts/Helicopter.gd"

var _relPath: String = ""
const LERP_SPEED: float = 8.0


func _physics_process(delta: float) -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
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
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(_relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    global_transform.origin = global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    global_transform.basis = global_transform.basis.slerp(targetBasis, blend)


func FireRockets() -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        super.FireRockets()
        return
