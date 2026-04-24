## Patch for Mine.gd — host-authoritative detonation; clients request via RPC.
extends "res://Scripts/Mine.gd"

var _cachedPath: String = ""


func _ready() -> void:
    super._ready()
    _cachedPath = get_tree().current_scene.get_path_to(self)


func Detonate() -> void:
    if CoopManager.is_session_active():
        if CoopManager.isHost:
            CoopManager.worldState.broadcast_mine_detonate(_cachedPath, false)
            super.Detonate()
        else:
            CoopManager.worldState.request_mine_detonate.rpc_id(1, _cachedPath, false)
        return
    super.Detonate()


func InstantDetonate() -> void:
    if CoopManager.is_session_active():
        if CoopManager.isHost:
            CoopManager.worldState.broadcast_mine_detonate(_cachedPath, true)
            super.InstantDetonate()
        else:
            CoopManager.worldState.request_mine_detonate.rpc_id(1, _cachedPath, true)
        return
    super.InstantDetonate()
