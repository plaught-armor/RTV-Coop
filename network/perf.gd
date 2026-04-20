## Lightweight scope-timer profiler for hot paths. Manual instrumentation via:
##   var _t: int = Perf.start()
##   ...code...
##   Perf.stop("label", _t)
## Auto-dumps accumulated stats every PERF_DUMP_TICKS (1s @ 60Hz physics).
## Disable globally by flipping ENABLED to false — wrap calls cost ~10ns when off.
## class_name removed — ModLoader-loaded scripts don't register globally for
## consumers; consumers must preload this file:
##   const Perf = preload("res://mod/network/perf.gd")
extends RefCounted


const ENABLED: bool = true
const PERF_DUMP_TICKS: int = 60


static var _totals: Dictionary = {}
static var _counts: Dictionary = {}
static var _maxes: Dictionary = {}
static var _lastDumpFrame: int = -1


static func start() -> int:
    if !ENABLED:
        return 0
    return Time.get_ticks_usec()


static func stop(label: String, startUsec: int) -> void:
    if !ENABLED:
        return
    var elapsed: int = Time.get_ticks_usec() - startUsec
    _totals[label] = _totals.get(label, 0) + elapsed
    _counts[label] = _counts.get(label, 0) + 1
    var mx: int = _maxes.get(label, 0)
    if elapsed > mx:
        _maxes[label] = elapsed


## Call once per physics frame from any tick-driven node. Auto-dumps + resets
## every PERF_DUMP_TICKS frames.
static func tick() -> void:
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
    keys.sort_custom(func(a, b): return _totals[a] > _totals[b])
    for k in keys:
        var total: int = _totals[k]
        var count: int = _counts[k]
        var avg: float = float(total) / float(count)
        var mx: int = _maxes[k]
        print("[Perf]  %-28s tot=%6dus cnt=%5d avg=%6.1fus max=%5dus" % [k, total, count, avg, mx])
    _totals.clear()
    _counts.clear()
    _maxes.clear()
