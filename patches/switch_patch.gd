## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Switch.gd"

var _cm: Node
## Scene-relative path, cached at _ready.
var _cachedPath: String = ""


func init_manager(manager: Node) -> void:
    _cm = manager


## Switch.gd has no _ready; do NOT call super._ready() per project rules.
func _ready() -> void:
    _cachedPath = get_tree().current_scene.get_path_to(self)


func Interact():
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    var switchPath: String = _cachedPath
    if _cm.isHost:
        super.Interact()
        _cm.worldState.sync_switch_state.rpc(switchPath, active)
    else:
        _cm.worldState.request_switch_interact.rpc_id(1, switchPath)
