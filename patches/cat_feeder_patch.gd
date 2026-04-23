## Patch for CatFeeder.gd — broadcasts gameData.cat change after feeding so
## peers see the same cat hydration / death state.
extends "res://Scripts/CatFeeder.gd"

var _cm: Node = null


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


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
