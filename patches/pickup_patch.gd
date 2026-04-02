## Patch for [code]Pickup.gd[/code] — host-authoritative pickup interactions.
## Host validates pickup exists and marks it consumed. The requesting peer
## then adds the item to their own inventory. Prevents duplication.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Pickup.gd"

func Interact():
    if !CoopManager.isActive:
        super.Interact()
        return

    if CoopManager.isHost:
        # Host picks up directly — validate, consume, broadcast
        if TryPickup():
            var pickupPath: String = get_tree().current_scene.get_path_to(self)
            remove_from_group(&"Item")
            CoopManager.worldState.SyncPickupConsumed.rpc(pickupPath)
            queue_free()
    else:
        # Client requests the host to validate
        var pickupPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.RequestPickupInteract.rpc_id(1, pickupPath)


## Attempts to add this pickup's item to the local player's inventory.
## Returns true if successful, false if inventory is full.
func TryPickup() -> bool:
    if interface.AutoStack(slotData, interface.inventoryGrid):
        interface.UpdateStats(false)
        PlayPickup()
        return true
    elif interface.Create(slotData, interface.inventoryGrid, false):
        interface.UpdateStats(false)
        PlayPickup()
        return true
    else:
        interface.PlayError()
        return false
