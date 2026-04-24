## Patch for Interactor.gd — co-op dispatch choke-point for Interactable targets (host broadcasts, client requests).
extends "res://Scripts/Interactor.gd"




func Interact():
    if !Input.is_action_just_pressed(("interact")):
        return

    if !CoopManager.is_session_active():
        super.Interact()
        return

    if !is_instance_valid(target):
        return

    if gameData.decor:
        super.Interact()
        return

    if target.is_in_group(&"Item"):
        gameData.interaction = true
        var syncId: String = target.get_meta(&"sync_id", "") if target.has_meta(&"sync_id") else ""
        target.Interact()
        # queue_free() marker tells us base Interact consumed the pickup; broadcast sync_id removal.
        if !syncId.is_empty() && target.is_queued_for_deletion():
            if CoopManager.isHost:
                CoopManager.worldState.on_synced_item_picked_up(syncId)
            else:
                CoopManager.worldState.request_item_consumed.rpc_id(1, syncId)
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
        if CoopManager.dispatch_interact(target.owner):
            if CoopManager.DEBUG:
                print("[interactor_patch] coop-dispatched %s" % target.owner.name)
            return
        target.owner.Interact()
