## Patch for GrenadeRig.gd — broadcasts throw params so remotes spawn matching grenades.
extends "res://Scripts/GrenadeRig.gd"




func ThrowHighExecute() -> void:
    var grenadeScene: String = throw.resource_path if throw != null else ""
    var handleScene: String = handle.resource_path if handle != null else ""
    var throwDir: Vector3 = global_transform.basis.z
    var throwPos: Vector3 = throwPoint.global_position
    var throwRotY: float = global_rotation_degrees.y
    var throwBasisX: Vector3 = global_transform.basis.x
    var throwForce: float = 30.0

    super.ThrowHighExecute()

    if CoopManager.is_session_active() && !grenadeScene.is_empty():
        CoopManager.playerState.broadcast_grenade_throw(
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

    if CoopManager.is_session_active() && !grenadeScene.is_empty():
        CoopManager.playerState.broadcast_grenade_throw(
            grenadeScene, handleScene, throwPos, throwRotY,
            throwDir, throwBasisX, throwForce,
        )
