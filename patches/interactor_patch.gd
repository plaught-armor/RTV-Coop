## Patch for Interactor.gd — co-op dispatch choke-point for Interactable targets (host broadcasts, client requests).
extends "res://Scripts/Interactor.gd"

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


func Interact():
    if !Input.is_action_just_pressed(("interact")):
        return

    if !_ensure_cm() || !_cm.is_session_active():
        super.Interact()
        return

    if !is_instance_valid(target):
        return

    if gameData.decor:
        super.Interact()
        return

    if target.is_in_group(&"Item"):
        gameData.interaction = true
        target.Interact()
        return

    if target.is_in_group(&"Transition"):
        if !is_instance_valid(target.owner):
            return
        if !target.owner.locked:
            gameData.isTransitioning = true
            target.owner.Interact()
        else:
            target.owner.Interact()
        return

    if target.is_in_group(&"Interactable"):
        if !is_instance_valid(target.owner):
            return
        if _cm.dispatch_interact(target.owner):
            if _cm.DEBUG:
                print("[interactor_patch] coop-dispatched %s" % target.owner.name)
            return
        target.owner.Interact()
