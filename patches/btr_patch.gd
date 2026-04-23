## Patch for BTR.gd — host-authoritative; clients freeze and lerp host snapshots.
extends "res://Scripts/BTR.gd"

var _cm: Node = null
var _relPath: String = ""
const LERP_SPEED: float = 8.0


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
    if !freeze:
        freeze = true
    Tires(delta)
    Suspension(delta)
    Audio(delta)
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
    var towerNode: Node = get_node_or_null(^"Chassis/Tower")
    if is_instance_valid(towerNode) && towerNode is Node3D:
        var t: Node3D = towerNode as Node3D
        t.rotation.y = lerp_angle(t.rotation.y, snap.turret as float, blend)


func Fire(delta: float) -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super.Fire(delta)
        return
