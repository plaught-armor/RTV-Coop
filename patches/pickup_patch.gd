## Patch for Pickup.gd — host-authoritative pickup broadcasting via sync_id meta.
extends "res://Scripts/Pickup.gd"




func _ready():
    super._ready()


func Interact():
    if !CoopManager.is_session_active():
        super.Interact()
        return

    if interface.AutoStack(slotData, interface.inventoryGrid):
        interface.UpdateStats(false)
        PlayPickup()
        if has_meta(&"sync_id"):
            var syncId: String = get_meta(&"sync_id")
            if CoopManager.isHost:
                CoopManager.worldState.on_synced_item_picked_up(syncId)
            else:
                CoopManager.worldState.request_item_consumed.rpc_id(1, syncId)
        queue_free()

    elif interface.Create(slotData, interface.inventoryGrid, false):
        interface.UpdateStats(false)
        PlayPickup()
        if has_meta(&"sync_id"):
            var syncId: String = get_meta(&"sync_id")
            if CoopManager.isHost:
                CoopManager.worldState.on_synced_item_picked_up(syncId)
            else:
                CoopManager.worldState.request_item_consumed.rpc_id(1, syncId)
        queue_free()

    else:
        interface.PlayError()
