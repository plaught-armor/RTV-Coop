## Patch for [code]Interactor.gd[/code] — co-op dispatch for all Interactable targets.
##
## Single choke-point replaces per-target patches (Door/Switch/Bed/Fire/LootContainer/Trader).
## In single-player (no session), falls through to the original [method Interact].
## In co-op:
##   - Host: runs original Interact, broadcasts resulting state.
##   - Client: suppresses local Interact, sends request to host.
extends "res://Scripts/Interactor.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


## Lazy CoopManager lookup — inject_manager may not have reached this node yet.
func _ensure_cm() -> void:
    if is_instance_valid(_cm):
        return
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return


func Interact():
    if !Input.is_action_just_pressed(("interact")):
        return

    _ensure_cm()

    # Solo — unchanged behaviour.
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    if !is_instance_valid(target):
        return

    # Decor editing — unchanged (no network sync needed for furniture placement mode).
    if gameData.decor:
        super.Interact()
        return

    # Item pickups handled by pickup_patch — pass through.
    if target.is_in_group(&"Item"):
        gameData.interaction = true
        target.Interact()
        return

    # Transitions handled by transition_patch — pass through.
    if target.is_in_group(&"Transition"):
        if !is_instance_valid(target.owner):
            return
        if !target.owner.locked:
            gameData.isTransitioning = true
            target.owner.Interact()
        else:
            target.owner.Interact()
        return

    # Interactable dispatch — Door/Switch/Bed/Fire/LootContainer/Trader.
    if target.is_in_group(&"Interactable"):
        if !is_instance_valid(target.owner):
            return
        if _cm.dispatch_interact(target.owner):
            if _cm.DEBUG:
                print("[interactor_patch] coop-dispatched %s" % target.owner.name)
            return
        # Not a dispatched type — fall through to local Interact.
        target.owner.Interact()
