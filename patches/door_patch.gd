## Patch for [code]Door.gd[/code] — routes interactions through the host for co-op sync.
## In single-player (not connected), falls through to the original [method Interact].
extends "res://Scripts/Door.gd"

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
        # Host runs the original interaction logic
        super.Interact()
        # Broadcast the resulting state to all clients
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.sync_door_state.rpc(doorPath, isOpen)
    else:
        # Client requests the host to do it
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.request_door_interact.rpc_id(1, doorPath)


func CheckKey():
    super.CheckKey()

    if !_get_cm().is_session_active():
        return

    # If the key check succeeded (locked is now false), broadcast the unlock
    if !locked && _get_cm().isHost:
        var doorPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.sync_door_unlock.rpc(doorPath)
        if linked:
            var linkedPath: String = get_tree().current_scene.get_path_to(linked)
            _get_cm().worldState.sync_door_unlock.rpc(linkedPath)
