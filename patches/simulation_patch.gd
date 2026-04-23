## Patch for Simulation.gd — applies host-auth day/night rate multipliers on top of vanilla tick.
extends "res://Scripts/Simulation.gd"

var _cm: Node

const DEFAULT_DAY_MULT: float = 1.0
const DEFAULT_NIGHT_MULT: float = 1.0


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


func _process(delta: float) -> void:
    super._process(delta)
    if !simulate:
        return
    if !_ensure_cm():
        return
    var mult: float = _current_multiplier()
    # Add only the extra advance: next frame's super() handles >2400 rollover.
    if mult != 1.0:
        time += rate * (mult - 1.0) * delta


# Night window 2100-500 matches game's TOD thresholds.
func _current_multiplier() -> float:
    var isNight: bool = time >= 2100.0 || time < 500.0
    if _cm == null:
        return DEFAULT_NIGHT_MULT if isNight else DEFAULT_DAY_MULT
    var key: String = "night_rate_multiplier" if isNight else "day_rate_multiplier"
    var fallback: float = DEFAULT_NIGHT_MULT if isNight else DEFAULT_DAY_MULT
    return float(_cm.get_setting(key, fallback))
