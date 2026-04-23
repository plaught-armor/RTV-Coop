## Patch for Television.gd — routes Interact() toggle through host.
extends "res://Scripts/Television.gd"

var _cm: Node = null


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
