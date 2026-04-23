## Scope-timer profiler with auto-dump every PERF_DUMP_TICKS; flip ENABLED to disable.
extends RefCounted


const ENABLED: bool = true
const PERF_DUMP_TICKS: int = 60


var _totals: Dictionary = {}
var _counts: Dictionary = {}
var _maxes: Dictionary = {}
var _lastDumpFrame: int = -1


func start() -> int:
    if !ENABLED:
        return 0
    return Time.get_ticks_usec()


func stop(label: String, startUsec: int) -> void:
    if !ENABLED:
        return
    var elapsed: int = Time.get_ticks_usec() - startUsec
    _totals[label] = _totals.get(label, 0) + elapsed
    _counts[label] = _counts.get(label, 0) + 1
    var mx: int = _maxes.get(label, 0)
    if elapsed > mx:
        _maxes[label] = elapsed


## Auto-dumps + resets every PERF_DUMP_TICKS frames.
func tick() -> void:
    if !ENABLED:
        return
    var f: int = Engine.get_physics_frames()
    if _lastDumpFrame == f:
        return
    _lastDumpFrame = f
    if f % PERF_DUMP_TICKS != 0 || _counts.is_empty():
        return
    print("[Perf] --- %d-tick window ---" % PERF_DUMP_TICKS)
    var keys: Array = _totals.keys()
    keys.sort_custom(_sort_keys_by_total_desc)
    for k in keys:
        var total: int = _totals[k]
        var count: int = _counts[k]
        var avg: float = float(total) / float(count)
        var mx: int = _maxes[k]
        print("[Perf]  %-28s tot=%6dus cnt=%5d avg=%6.1fus max=%5dus" % [k, total, count, avg, mx])
    _totals.clear()
    _counts.clear()
    _maxes.clear()


func _sort_keys_by_total_desc(a: Variant, b: Variant) -> bool:
    return _totals[a] > _totals[b]
