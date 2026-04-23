## Patch for Character.gd — broadcasts death to peers when session active.
extends "res://Scripts/Character.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func Death() -> void:
    if is_instance_valid(_cm) && _cm.is_session_active():
        _cm.playerState.broadcast_death()
    super.Death()
