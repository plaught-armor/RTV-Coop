## Patch for Transition.gd — independent map transitions; mirrors user://*.tres into per-world dir.
extends "res://Scripts/Transition.gd"




func _ready() -> void:
    super._ready()


func Interact() -> void:
    if CoopManager != null && CoopManager.DEBUG:
        print("[TX] Interact begin nextMap=%s" % nextMap)
    super.Interact()
    # Client's savePath already points at coop dir; mirror is only needed for host/solo.
    if CoopManager.is_session_active() && CoopManager.isHost:
        CoopManager.saveMirror.mirror_user_to_world()
    elif !CoopManager.is_session_active():
        CoopManager.saveMirror.mirror_user_to_solo()
    if CoopManager.DEBUG:
        print("[TX] Interact end")
