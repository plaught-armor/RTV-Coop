## Applies coop-tunable day/night rate multipliers on top of the base-game
## Simulation ticker. Host-authoritative settings pushed via
## [member CoopManager.settings] — clients see the same multiplied rate so
## everyone's local time advance matches before the next [code]sync_simulation[/code]
## snapshot arrives.
extends "res://Scripts/Simulation.gd"

var _cm: Node

const DEFAULT_DAY_MULT: float = 1.0
const DEFAULT_NIGHT_MULT: float = 1.0


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


func _process(delta: float) -> void:
    # Run vanilla tick first — advances time/weather + handles new-day rollover.
    # Any future base additions benefit automatically.
    super._process(delta)
    if !simulate:
        return
    _ensure_cm()
    var mult: float = _current_multiplier()
    # Apply only the EXTRA advance from the multiplier. mult=1 → no-op.
    # Next-frame's super() handles the >2400 rollover if we pushed past it.
    if mult != 1.0:
        time += rate * (mult - 1.0) * delta


## 2400.0 tick-ticks of time per in-game day. Night window is 2100–500 (matches
## the game's own TOD thresholds); everything else is day.
func _current_multiplier() -> float:
    var isNight: bool = time >= 2100.0 || time < 500.0
    if _cm == null:
        return DEFAULT_NIGHT_MULT if isNight else DEFAULT_DAY_MULT
    var key: String = "night_rate_multiplier" if isNight else "day_rate_multiplier"
    var fallback: float = DEFAULT_NIGHT_MULT if isNight else DEFAULT_DAY_MULT
    return float(_cm.get_setting(key, fallback))
