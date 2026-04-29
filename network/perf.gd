## Scope-timer profiler with auto-dump every PERF_DUMP_TICKS; flip ENABLED to disable.
extends RefCounted


const ENABLED: bool = true
const PERF_DUMP_TICKS: int = 60


var _totals: Dictionary[String, int] = {}
var _counts: Dictionary[String, int] = {}
var _maxes: Dictionary[String, int] = {}
var _lastDumpFrame: int = -1


func start() -> int:
    if !ENABLED:
        return 0
    return Time.get_ticks_usec()


func stop(label: String, startUsec: int) -> void:
    if !ENABLED:
        return
    var elapsed: int = Time.get_ticks_usec() - startUsec
    var prevTotal: int = _totals[label] if _totals.has(label) else 0
    var prevCount: int = _counts[label] if _counts.has(label) else 0
    var prevMax: int = _maxes[label] if _maxes.has(label) else 0
    _totals[label] = prevTotal + elapsed
    _counts[label] = prevCount + 1
    if elapsed > prevMax:
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
    var keys: Array[String] = _totals.keys()
    keys.sort_custom(_sort_keys_by_total_desc)
    for k: String in keys:
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
