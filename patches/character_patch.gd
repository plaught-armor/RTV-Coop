## Patch for Character.gd — broadcasts death to peers when session active.
extends "res://Scripts/Character.gd"

const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func Death() -> void:
    if _ensure_cm() && _cm.is_session_active():
        _cm.playerState.broadcast_death()
    super.Death()
