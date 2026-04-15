## Patch for [code]Door.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Door.gd"

var _cm: Node
## Scene-relative path, cached at _ready.
var _cachedPath: String = ""


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()
    _cachedPath = get_tree().current_scene.get_path_to(self)


## Lazy CoopManager lookup — inject_manager may not have reached this node yet.
func _ensure_cm() -> void:
    if is_instance_valid(_cm):
        return
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return


func Interact():
    _ensure_cm()
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    var doorPath: String = _cachedPath
    if _cm.isHost:
        super.Interact()
        _cm.worldState.sync_door_state.rpc(doorPath, isOpen)
    else:
        _cm.worldState.request_door_interact.rpc_id(1, doorPath)


func CheckKey():
    _ensure_cm()
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.CheckKey()
        return

    if _cm.isHost:
        super.CheckKey()
        if !locked:
            var doorPath: String = _cachedPath
            _cm.worldState.sync_door_unlock.rpc(doorPath)
            if is_instance_valid(linked):
                var linkedPath: String = get_tree().current_scene.get_path_to(linked)
                _cm.worldState.sync_door_unlock.rpc(linkedPath)
    else:
        # Clients request host to check key — don't consume locally
        var doorPath: String = _cachedPath
        _cm.worldState.request_door_interact.rpc_id(1, doorPath)
