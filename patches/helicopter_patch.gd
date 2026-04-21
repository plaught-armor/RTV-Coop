## Patch for [code]Helicopter.gd[/code] — makes the helicopter host-authoritative
## in co-op sessions. Host runs the full state machine (Patrol / Flyby / Attack
## + sensor + searchlight) unchanged via [code]super[/code]. Clients skip every
## bit of gameplay logic and lerp the visual toward snapshots from
## [code]vehicle_state.gd[/code].
##
## [method FireRockets] is suppressed on clients — host's rockets spawn in the
## host's world; replicating the spawn point adds bandwidth for what the notes
## call "cosmetic divergence".
extends "res://Scripts/Helicopter.gd"

var _cm: Node = null
## Cached scene-relative path for snapshot lookup. Resolved on first client tick.
var _relPath: String = ""
## Interpolation strength per second. Higher = snappier + more jitter; lower =
## smoother + more visible latency. Matches the empirical tune used on remote
## players.
const LERP_SPEED: float = 8.0


## Resolves a reference to the autoload lazily — [code]take_over_path[/code]
## replaces the script before autoloads finish wiring, so a preload would
## return [code]null[/code] on first instantiation.
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


func _physics_process(delta: float) -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super._physics_process(delta)
        return
    # Client path: cosmetic rotor spin + despawn safety + snapshot lerp.
    # No state machine, no sensor, no searchlight roll — host owns those.
    RotorBlades(delta)
    DistanceClear()
    _apply_host_snapshot(delta)


func _apply_host_snapshot(delta: float) -> void:
    if _relPath.is_empty():
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            _relPath = String(scene.get_path_to(self))
    if _relPath.is_empty():
        return
    var snap: Dictionary = _cm.vehicleState.get_snapshot(_relPath)
    if snap.is_empty():
        return
    var blend: float = clamp(delta * LERP_SPEED, 0.0, 1.0)
    global_transform.origin = global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    global_transform.basis = global_transform.basis.slerp(targetBasis, blend)


func FireRockets() -> void:
    if !_ensure_cm() || !_cm.is_session_active() || _cm.isHost:
        super.FireRockets()
        return
    # Client: host-auth — rockets spawn on host only. Visual divergence accepted.
