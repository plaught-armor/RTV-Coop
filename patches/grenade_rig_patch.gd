## Patch for GrenadeRig.gd — broadcasts throw params so remotes spawn matching grenades.
extends "res://Scripts/GrenadeRig.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


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


func ThrowHighExecute() -> void:
    var grenadeScene: String = throw.resource_path if throw != null else ""
    var handleScene: String = handle.resource_path if handle != null else ""
    var throwDir: Vector3 = global_transform.basis.z
    var throwPos: Vector3 = throwPoint.global_position
    var throwRotY: float = global_rotation_degrees.y
    var throwBasisX: Vector3 = global_transform.basis.x
    var throwForce: float = 30.0

    super.ThrowHighExecute()

    if _ensure_cm() && _cm.is_session_active() && !grenadeScene.is_empty():
        _cm.playerState.broadcast_grenade_throw(
            grenadeScene, handleScene, throwPos, throwRotY,
            throwDir, throwBasisX, throwForce,
        )


func ThrowLowExecute() -> void:
    var grenadeScene: String = throw.resource_path if throw != null else ""
    var handleScene: String = handle.resource_path if handle != null else ""
    var throwDir: Vector3 = global_transform.basis.z
    var throwPos: Vector3 = throwPoint.global_position
    var throwRotY: float = global_rotation_degrees.y
    var throwBasisX: Vector3 = global_transform.basis.x
    var throwForce: float = 15.0

    super.ThrowLowExecute()

    if _ensure_cm() && _cm.is_session_active() && !grenadeScene.is_empty():
        _cm.playerState.broadcast_grenade_throw(
            grenadeScene, handleScene, throwPos, throwRotY,
            throwDir, throwBasisX, throwForce,
        )
