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
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func Interact() -> void:
    print("[TX] Interact begin nextMap=%s" % nextMap)
    super.Interact()
    if !_ensure_cm():
        print("[TX] Interact end (solo, no cm)")
        return
    # Client's savePath already points at coop dir; mirror is only needed for host/solo.
    if _cm.is_session_active() && _cm.isHost:
        _cm.mirror_user_to_world()
    elif !_cm.is_session_active():
        _cm.mirror_user_to_solo()
    print("[TX] Interact end")
