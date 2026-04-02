## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Switch.gd"

func Interact() -> void:
	if !CoopManager.isActive:
		super.Interact()
		return

	if CoopManager.isHost:
		super.Interact()
		var switchPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.SyncSwitchState.rpc(switchPath, active)
	else:
		var switchPath: String = get_tree().current_scene.get_path_to(self)
		CoopManager.worldState.RequestSwitchInteract.rpc_id(1, switchPath)
