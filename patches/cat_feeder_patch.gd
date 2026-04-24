## Patch for CatFeeder.gd — broadcasts gameData.cat change after feeding so
## peers see the same cat hydration / death state.
extends "res://Scripts/CatFeeder.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func TryFeeding() -> void:
    var before: float = gameData.cat
    super.TryFeeding()
    if !_ensure_cm() || !_cm.is_session_active():
        return
    if gameData.cat == before:
        return
    if _cm.isHost:
        _cm.worldState.broadcast_cat_state.rpc(gameData.catFound, gameData.catDead, gameData.cat)
    else:
        _cm.worldState.request_cat_state.rpc_id(1, gameData.catFound, gameData.catDead, gameData.cat)
