## Patch for [code]Door.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Door.gd"

func Interact():
    if !CoopManager.is_connected():
        super.Interact()
        return

    if CoopManager.isHost:
        # Host runs the original interaction logic
        super.Interact()
        # Broadcast the resulting state to all clients
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.sync_door_state.rpc(doorPath, isOpen)
    else:
        # Client requests the host to do it
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.request_door_interact.rpc_id(1, doorPath)


func CheckKey():
    super.CheckKey()

    if !CoopManager.is_connected():
        return

    # If the key check succeeded (locked is now false), broadcast the unlock
    if !locked && CoopManager.isHost:
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.sync_door_unlock.rpc(doorPath)
        if linked:
            var linkedPath: String = get_tree().current_scene.get_path_to(linked)
            CoopManager.worldState.sync_door_unlock.rpc(linkedPath)
