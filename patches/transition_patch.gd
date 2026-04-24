## Patch for Transition.gd — independent map transitions; mirrors user://*.tres into per-world dir.
extends "res://Scripts/Transition.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    super._ready()


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func Interact() -> void:
    if _cm != null && _cm.DEBUG:
        print("[TX] Interact begin nextMap=%s" % nextMap)
    super.Interact()
    if !_ensure_cm():
        return
    # Client's savePath already points at coop dir; mirror is only needed for host/solo.
    if _cm.is_session_active() && _cm.isHost:
        _cm.mirror_user_to_world()
    elif !_cm.is_session_active():
        _cm.mirror_user_to_solo()
    if _cm.DEBUG:
        print("[TX] Interact end")
