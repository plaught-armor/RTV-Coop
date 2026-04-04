## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Switch.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func Interact():
    if _cm == null || !_cm.is_session_active():
        super.Interact()
        return

    var switchPath: String = get_tree().current_scene.get_path_to(self)
    if _cm.isHost:
        super.Interact()
        _cm.worldState.sync_switch_state.rpc(switchPath, active)
    else:
        _cm.worldState.request_switch_interact.rpc_id(1, switchPath)
