## Patch for [code]Door.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Door.gd"

func Interact() -> void:
	if !CoopManager.isActive:
		super.Interact()
		return

	if CoopManager.isHost:
		# Host runs the interaction locally and broadcasts
		super.Interact()
		var doorPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.SyncDoorState.rpc(doorPath, isOpen)
	else:
		# Client requests the host to do it
		var doorPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.RequestDoorInteract.rpc_id(1, doorPath)


func CheckKey() -> void:
	super.CheckKey()

	if !CoopManager.isActive:
		return

	# If the key check succeeded (locked is now false), broadcast the unlock
	if !locked && CoopManager.isHost:
		var doorPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.SyncDoorUnlock.rpc(doorPath)
		if linked:
			var linkedPath: String = get_tree().current_scene.get_path_to(linked)
			CoopManager.worldState.SyncDoorUnlock.rpc(linkedPath)
