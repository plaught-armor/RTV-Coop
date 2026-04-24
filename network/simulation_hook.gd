## Applies host-auth day/night rate multiplier on top of vanilla Simulation tick.
##
## Vanilla Simulation._process advances `time += rate * delta`. Coop settings
## "day_rate_multiplier" / "night_rate_multiplier" let host speed up or slow
## down the TOD. Instead of patching Simulation.gd, we poll from CoopManager
## each frame and add the extra advance.
extends RefCounted


const DEFAULT_MULT: float = 1.0
const NIGHT_START: float = 2100.0
const NIGHT_END: float = 500.0

var _cm: Node
var _sim: Node = null


func init_manager(manager: Node) -> void:
    _cm = manager


func apply(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        return
    if !is_instance_valid(_sim):
        _sim = _cm.get_node_or_null(^"/root/Simulation")
        if _sim == null:
            return
    if !_sim.simulate:
        return
    var mult: float = _current_multiplier(_sim.time)
    if mult == 1.0:
        return
    # Next frame's Simulation._process handles the >= 2400 rollover.
    _sim.time += _sim.rate * (mult - 1.0) * delta


func _current_multiplier(time: float) -> float:
    var isNight: bool = time >= NIGHT_START || time < NIGHT_END
    var key: String = "night_rate_multiplier" if isNight else "day_rate_multiplier"
    return float(_cm.get_setting(key, DEFAULT_MULT))
