## Patch for [code]Pickup.gd[/code] — host-authoritative pickup interactions.
## Host validates pickup exists and marks it consumed. The requesting peer
## then adds the item to their own inventory. Prevents duplication.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Pickup.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
	_cm = manager


func _ready():
	super._ready()


func Interact():
	if _cm == null || !_cm.is_session_active():
		super.Interact()
		return

	var pickupPath: String = get_tree().current_scene.get_path_to(self)
	if _cm.isHost:
		if TryPickup():
			remove_from_group(&"Item")
			_cm.worldState.sync_pickup_consumed.rpc(pickupPath)
			queue_free()
	else:
		_cm.worldState.request_pickup_interact.rpc_id(1, pickupPath)


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
