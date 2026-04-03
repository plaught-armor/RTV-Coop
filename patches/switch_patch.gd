## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
## Note: Host-side switch toggling is handled in [code]WorldState.RequestSwitchInteract[/code]
## directly (not via this patch) to avoid double-broadcast.
extends "res://Scripts/Switch.gd"

var _cm: Node


func _get_cm() -> Node:
    if _cm == null:
        _cm = get_node("/root/CoopManager")
    return _cm


func Interact():
    if !_get_cm().is_session_active():
        super.Interact()
        return

    if _get_cm().isHost:
        # Host runs original logic and broadcasts
        super.Interact()
        var switchPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.sync_switch_state.rpc(switchPath, active)
    else:
        # Client requests the host to do it
        var switchPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.request_switch_interact.rpc_id(1, switchPath)
