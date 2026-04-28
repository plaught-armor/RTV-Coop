## Hook callbacks for Interactor.gd — coop dispatch choke-point.
## Replaces patches/interactor_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("interactor-interact", _on_interact)


func _on_interact() -> void:
    if !Input.is_action_just_pressed("interact"):
        _lib.skip_super()
        return
    CoopManager._log("[interactor.trace] press detected")
    if !CoopManager.is_session_active():
        return  # vanilla runs
    var ix: Node = _lib._caller
    if ix == null:
        CoopManager._log("[interactor.trace] caller null")
        return
    var target: Node = ix.target
    if !is_instance_valid(target):
        _lib.skip_super()
        CoopManager._log("[interactor] ABORT invalid target")
        return
    CoopManager._log("[interactor.trace] target=%s groups=%s" % [target.name, str(target.get_groups())])
    if ix.gameData.decor:
        CoopManager._log("[interactor] decor-mode passthrough")
        return  # let vanilla run -- handles decor + Furniture group Catalog cascade
    _lib.skip_super()
    var ownerName: String = target.owner.name if is_instance_valid(target.owner) else "<none>"
    if target.is_in_group(&"Item"):
        ix.gameData.interaction = true
        var syncId: String = target.get_meta(&"sync_id", "") if target.has_meta(&"sync_id") else ""
        var ownerType: String = "<none>"
        if is_instance_valid(target.owner):
            var ownerScript: Script = target.owner.get_script()
            ownerType = ownerScript.resource_path if ownerScript != null else target.owner.get_class()
        CoopManager._log("[interactor] ITEM target=%s sync_id=%s owner=%s ownerType=%s" % [target.name, syncId, ownerName, ownerType])
        target.Interact()
        if !syncId.is_empty() && target.is_queued_for_deletion():
            if CoopManager.isHost:
                CoopManager._log("[interactor] pickup consumed (HOST path) id=%s" % syncId)
                CoopManager.worldState.on_synced_item_picked_up(syncId)
            else:
                CoopManager._log("[interactor] pickup consumed (CLIENT path) id=%s -> request_item_consumed" % syncId)
                CoopManager.worldState.request_item_consumed.rpc_id(1, syncId)
        return
    if target.is_in_group(&"Transition"):
        if !is_instance_valid(target.owner):
            CoopManager._log("[interactor] TRANSITION ABORT invalid owner")
            return
        CoopManager._log("[interactor] TRANSITION owner=%s locked=%s" % [ownerName, str(target.owner.locked)])
        if !target.owner.locked:
            ix.gameData.isTransitioning = true
        target.owner.Interact()
        if CoopManager.is_session_active() && CoopManager.isHost:
            CoopManager._log("[transition] mirror user->world (host)")
            CoopManager.saveMirror.mirror_user_to_world()
        elif !CoopManager.is_session_active():
            CoopManager._log("[transition] mirror user->solo")
            CoopManager.saveMirror.mirror_user_to_solo()
        return
    if target.is_in_group(&"Interactable"):
        if !is_instance_valid(target.owner):
            CoopManager._log("[interactor] INTERACTABLE ABORT invalid owner")
            return
        if CoopManager.dispatch_interact(target.owner):
            CoopManager._log("[interactor] coop-dispatched owner=%s" % ownerName)
            return
        CoopManager._log("[interactor] local Interact owner=%s" % ownerName)
        target.owner.Interact()
