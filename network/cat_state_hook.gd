## Broadcasts gameData cat state changes — replaces cat_feeder_patch and
## cat_rescue_patch. Both patches only fired broadcast_cat_state / request_cat_state
## after their Interact mutated gameData.cat / catFound / catDead. A poll watches
## the tuple from CoopManager._process and fires the RPC on change.
##
## Monotonic semantics in world_state mean one extra redundant RPC on clamp
## is harmless (host applies min, clients converge on same value).
extends RefCounted


var _lastCat: float = -1.0
var _lastFound: bool = false
var _lastDead: bool = false
var _primed: bool = false


func poll() -> void:
    if !CoopManager.is_session_active():
        _primed = false
        return
    var gd: GameData = CoopManager.gd
    if !_primed:
        _lastCat = gd.cat
        _lastFound = gd.catFound
        _lastDead = gd.catDead
        _primed = true
        return
    if gd.cat == _lastCat && gd.catFound == _lastFound && gd.catDead == _lastDead:
        return
    _lastCat = gd.cat
    _lastFound = gd.catFound
    _lastDead = gd.catDead
    if CoopManager.isHost:
        CoopManager.worldState.broadcast_cat_state.rpc(gd.catFound, gd.catDead, gd.cat)
    else:
        CoopManager.worldState.request_cat_state.rpc_id(1, gd.catFound, gd.catDead, gd.cat)
