## Patch for [code]Trader.gd[/code] — host-authoritative trading.
## Client requests supply from host on interact; host validates all trades.
extends "res://Scripts/Trader.gd"

var _cm: Node
var _cachedPath: String = ""


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    super._ready()
    _cachedPath = get_tree().current_scene.get_path_to(self)


func _ensure_cm() -> void:
    if is_instance_valid(_cm):
        return
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return


func Interact() -> void:
    _ensure_cm()
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    if _cm.isHost:
        # Host opens locally with authoritative supply.
        super.Interact()
    else:
        # Client requests supply from host, then opens UI on callback.
        _cm.worldState.request_trader_open.rpc_id(1, _cachedPath)
