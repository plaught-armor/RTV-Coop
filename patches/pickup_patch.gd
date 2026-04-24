## Patch for Pickup.gd — host-authoritative pickup broadcasting via sync_id meta.
extends "res://Scripts/Pickup.gd"

const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func _ready():
    super._ready()


func Interact():
    if !_ensure_cm() || !_cm.is_session_active():
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
