## Patch for Television.gd — routes Interact() toggle through host.
extends "res://Scripts/Television.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func Interact() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.Interact()
        return
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        super.Interact()
        return
    var relPath: String = String(scene.get_path_to(self))
    if _cm.isHost:
        super.Interact()
        _cm.worldState.broadcast_interact_toggle.rpc(relPath)
    else:
        _cm.worldState.request_interact_toggle.rpc_id(1, relPath)


func coop_remote_interact() -> void:
    super.Interact()
