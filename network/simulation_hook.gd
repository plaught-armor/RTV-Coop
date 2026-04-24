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


var _lockedWeather: String = ""


func apply(delta: float) -> void:
    if !CoopManager.is_session_active():
        return
    if !Simulation.simulate:
        return
    _apply_weather_lock()
    var mult: float = _current_multiplier(Simulation.time)
    if mult == 1.0:
        return
    # Next frame's Simulation._process handles the >= 2400 rollover.
    Simulation.time += Simulation.rate * (mult - 1.0) * delta


# Freezes Simulation.weather to its current value when lock toggled on.
# Unlocking clears the snapshot so vanilla weatherTime can cycle again.
func _apply_weather_lock() -> void:
    var locked: bool = CoopManager.get_setting("weather_locked", 0.0) >= 0.5
    if locked:
        if _lockedWeather.is_empty():
            _lockedWeather = str(Simulation.weather)
        elif str(Simulation.weather) != _lockedWeather:
            Simulation.weather = _lockedWeather
    elif !_lockedWeather.is_empty():
        _lockedWeather = ""


func _current_multiplier(time: float) -> float:
    var isNight: bool = time >= NIGHT_START || time < NIGHT_END
    var key: String = "night_rate_multiplier" if isNight else "day_rate_multiplier"
    return float(CoopManager.get_setting(key, DEFAULT_MULT))
