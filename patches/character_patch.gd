## Patch for [code]Character.gd[/code] — co-op death state broadcasting.
##
## Overrides:
## [br]- [method Death]: broadcasts death event to all peers so remote players
##   know when a player dies (AI behavior, HUD updates, respawn coordination)
##
## Original behaviour is 100% preserved when not in a co-op session.
extends "res://Scripts/Character.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func Death() -> void:
    if is_instance_valid(_cm) && _cm.is_session_active():
        _cm.playerState.broadcast_death()
    super.Death()
