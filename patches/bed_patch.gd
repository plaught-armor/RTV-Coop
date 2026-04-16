## Patch for [code]Bed.gd[/code] — co-op sleep coordination.
##
## Overrides:
## [br]- [method Interact]: blocks sleep in co-op (advancing time affects all players)
## [br]- [method UpdateTooltip]: shows disabled reason in co-op
##
## Sleep is disabled during co-op sessions because it advances Simulation time
## globally and freezes gameData, which would desync or freeze other players.
## Original behaviour is 100% preserved when not in a co-op session.
extends "res://Scripts/Bed.gd"

var _cm: Node


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
    if is_instance_valid(_cm) && _cm.is_session_active():
        Loader.Message("Cannot sleep during co-op", Color.RED)
        return
    super.Interact()


func UpdateTooltip() -> void:
    _ensure_cm()
    if is_instance_valid(_cm) && _cm.is_session_active():
        gameData.tooltip = "Sleep (Disabled in co-op)"
        return
    super.UpdateTooltip()
