## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
## Note: Host-side switch toggling is handled in [code]WorldState.RequestSwitchInteract[/code]
## directly (not via this patch) to avoid double-broadcast.
extends "res://Scripts/Switch.gd"

func Interact():
    if !CoopManager.is_connected():
        super.Interact()
        return

    if CoopManager.isHost:
        # Host runs original logic and broadcasts
        super.Interact()
        var switchPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.sync_switch_state.rpc(switchPath, active)
    else:
        # Client requests the host to do it
        var switchPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.request_switch_interact.rpc_id(1, switchPath)
