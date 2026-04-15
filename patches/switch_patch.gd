## Patch for [code]Switch.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Switch.gd"

var _cm: Node
## Cached scene-relative path to this switch. Stable for the node's lifetime;
## computed once at _ready so Interact() doesn't recompute on every use
## (get_path_to walks all ancestors).
var _cachedPath: String = ""


func init_manager(manager: Node) -> void:
    _cm = manager


## Switch.gd does not define _ready(), so per project rules we do NOT call
## super._ready() — just populate our own cache.
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
