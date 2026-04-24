## Broadcasts local player death — replaces character_patch.
##
## Vanilla Character.Death sets gameData.isDead = true. A poll on CoopManager
## watches for the edge and emits broadcast_death once per transition.
extends RefCounted


var _lastIsDead: bool = false


func poll() -> void:
    if !CoopManager.is_session_active():
        _lastIsDead = CoopManager.gd.isDead
        return
    var isDead: bool = CoopManager.gd.isDead
    if isDead && !_lastIsDead:
        CoopManager.playerState.broadcast_death()
    _lastIsDead = isDead
