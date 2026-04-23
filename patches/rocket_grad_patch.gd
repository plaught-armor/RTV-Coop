## Patch for RocketGrad.gd — host runs physics, clients lerp snapshot from
## vehicle_state. Rocket frees itself on host when cleared; client drops when
## snapshot goes stale (vehicle_state stops broadcasting).
@tool
extends "res://Scripts/RocketGrad.gd"

var _cm: Node = null
var _relPath: String = ""
const LERP_SPEED: float = 18.0


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    if Engine.is_editor_hint():
        return false
    var tree: SceneTree = get_tree()
    if tree == null:
        return false
    var root: Node = tree.root
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func _process(delta: float) -> void:
    if Engine.is_editor_hint():
        super._process(delta)
        return
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        # Broadcast cleanup BEFORE super runs — super may queue_free self, after
        # which `.rpc()` on a dying node is undefined.
        if _cm != null && _cm.is_session_active() && _cm.isHost && launched && global_position.z > abs(tracking) + 100.0:
            _cm.worldState.broadcast_rocket_cleanup.rpc(global_position)
        super._process(delta)
        return
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
