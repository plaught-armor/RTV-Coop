## Patch for Mine.gd — host-authoritative detonation; clients request via RPC.
extends "res://Scripts/Mine.gd"


# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")

var _cachedPath: String = ""


func _ready() -> void:
    super._ready()
    _cachedPath = get_tree().current_scene.get_path_to(self)


func Detonate() -> void:
    if CoopManager.is_session_active():
        CoopManager._log("[mine] Detonate path=%s host=%s" % [_cachedPath, str(CoopManager.isHost)])
        if CoopManager.isHost:
            CoopManager.worldState.broadcast_mine_detonate(_cachedPath, false)
            super.Detonate()
        else:
            CoopManager.worldState.request_mine_detonate.rpc_id(1, _cachedPath, false)
        return
    super.Detonate()


func InstantDetonate() -> void:
    if CoopManager.is_session_active():
        CoopManager._log("[mine] InstantDetonate path=%s host=%s" % [_cachedPath, str(CoopManager.isHost)])
        if CoopManager.isHost:
            CoopManager.worldState.broadcast_mine_detonate(_cachedPath, true)
            super.InstantDetonate()
        else:
            CoopManager.worldState.request_mine_detonate.rpc_id(1, _cachedPath, true)
        return
    super.InstantDetonate()
