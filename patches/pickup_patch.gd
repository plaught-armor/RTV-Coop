## Patch for Pickup.gd — host-authoritative pickup broadcasting via sync_id meta.
extends "res://Scripts/Pickup.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()


func Interact():
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    if interface.AutoStack(slotData, interface.inventoryGrid):
        interface.UpdateStats(false)
        PlayPickup()
        if has_meta(&"sync_id"):
            var syncId: String = get_meta(&"sync_id")
            if _cm.isHost:
                _cm.worldState.on_synced_item_picked_up(syncId)
            else:
                _cm.worldState.request_item_consumed.rpc_id(1, syncId)
        queue_free()

    elif interface.Create(slotData, interface.inventoryGrid, false):
        interface.UpdateStats(false)
        PlayPickup()
        if has_meta(&"sync_id"):
            var syncId: String = get_meta(&"sync_id")
            if _cm.isHost:
                _cm.worldState.on_synced_item_picked_up(syncId)
            else:
                _cm.worldState.request_item_consumed.rpc_id(1, syncId)
        queue_free()

    else:
        interface.PlayError()
