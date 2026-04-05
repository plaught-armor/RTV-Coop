## Patch for [code]Door.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Door.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()


func Interact():
    if _cm == null || !_cm.is_session_active():
        super.Interact()
        return

    var doorPath: String = get_tree().current_scene.get_path_to(self)
    if _cm.isHost:
        super.Interact()
        _cm.worldState.sync_door_state.rpc(doorPath, isOpen)
    else:
        _cm.worldState.request_door_interact.rpc_id(1, doorPath)


func CheckKey():
    if _cm == null || !_cm.is_session_active():
        super.CheckKey()
        return

    if _cm.isHost:
        super.CheckKey()
        if !locked:
            var doorPath: String = get_tree().current_scene.get_path_to(self)
            _cm.worldState.sync_door_unlock.rpc(doorPath)
            if linked:
                var linkedPath: String = get_tree().current_scene.get_path_to(linked)
                _cm.worldState.sync_door_unlock.rpc(linkedPath)
    else:
        # Clients request host to check key — don't consume locally
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        _cm.worldState.request_door_interact.rpc_id(1, doorPath)
