## Patch for CatRescue.gd — broadcasts catFound after rescue pickup so peers
## all light up the cat vital simultaneously.
extends "res://Scripts/CatRescue.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func Interact() -> void:
    super.Interact()
    if !_ensure_cm() || !_cm.is_session_active():
        return
    if !gameData.catFound:
        return
    if _cm.isHost:
        _cm.worldState.broadcast_cat_state.rpc(true, gameData.catDead, gameData.cat)
    else:
        _cm.worldState.request_cat_state.rpc_id(1, true, gameData.catDead, gameData.cat)
