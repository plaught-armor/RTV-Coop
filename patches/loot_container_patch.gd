## Patch for [code]LootContainer.gd[/code] — host-authoritative container interactions.
## Host generates and owns the loot array. Clients receive it via RPC.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/LootContainer.gd"

func Interact():
    if !CoopManager.IsConnected():
        super.Interact()
        return

    if CoopManager.isHost:
        super.Interact()
        # After opening, broadcast the current loot state
        var containerPath: String = get_tree().current_scene.get_path_to(self)
        var packedLoot: Array = SlotSerializer.PackArray(loot)
        CoopManager.worldState.SyncContainerState.rpc(containerPath, packedLoot)
    else:
        # Client requests to open the container
        var containerPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.RequestContainerOpen.rpc_id(1, containerPath)
