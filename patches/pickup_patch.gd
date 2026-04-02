## Patch for [code]Pickup.gd[/code] — host-authoritative pickup interactions.
## Host validates and broadcasts pickup consumption. Clients request via RPC.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Pickup.gd"

func Interact():
	if !CoopManager.isActive:
		super.Interact()
		return

	if CoopManager.isHost:
		# Host validates locally (inventory check) and broadcasts if consumed
		if interface.AutoStack(slotData, interface.inventoryGrid):
			interface.UpdateStats(false)
			PlayPickup()
			var pickupPath: String = get_tree().current_scene.get_path_to(self)
			CoopManager.worldState.SyncPickupConsumed.rpc(pickupPath)
			queue_free()
		elif interface.Create(slotData, interface.inventoryGrid, false):
			interface.UpdateStats(false)
			PlayPickup()
			var pickupPath: String = get_tree().current_scene.get_path_to(self)
			CoopManager.worldState.SyncPickupConsumed.rpc(pickupPath)
			queue_free()
		else:
			interface.PlayError()
	else:
		# Client requests the host to validate
		var pickupPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.RequestPickupInteract.rpc_id(1, pickupPath)
