## Hook callbacks for GrenadeRig.gd — broadcasts throw params so remotes spawn matching grenades.
## Replaces patches/grenade_rig_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Two hooks per throw method: pre-hook snapshots throw state into a per-instance staging
## dict (vanilla may null fields after super); post-hook reads + broadcasts.
extends RefCounted


var _lib: Object = null
var _staging: Dictionary[Node, Dictionary] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("grenaderig-throwhighexecute-pre", _on_high_pre)
    lib.hook("grenaderig-throwhighexecute-post", _on_high_post)
    lib.hook("grenaderig-throwlowexecute-pre", _on_low_pre)
    lib.hook("grenaderig-throwlowexecute-post", _on_low_post)


func _capture(rig: Node3D, force: float) -> void:
    var grenadeScene: String = rig.throw.resource_path if rig.throw != null else ""
    var handleScene: String = rig.handle.resource_path if rig.handle != null else ""
    _staging[rig] = {
        "grenadeScene": grenadeScene,
        "handleScene": handleScene,
        "throwDir": rig.global_transform.basis.z,
        "throwPos": rig.throwPoint.global_position,
        "throwRotY": rig.global_rotation_degrees.y,
        "throwBasisX": rig.global_transform.basis.x,
        "throwForce": force,
    }


func _broadcast(rig: Node3D, label: String) -> void:
    var s: Dictionary = _staging.get(rig, {})
    _staging.erase(rig)
    if s.is_empty():
        return
    var grenadeScene: String = s["grenadeScene"]
    if !CoopManager.is_session_active() || grenadeScene.is_empty():
        return
    CoopManager._log("[grenade] %s scene=%s pos=%s force=%.1f" % [label, grenadeScene, str(s["throwPos"]), s["throwForce"]])
    CoopManager.playerState.broadcast_grenade_throw(
        grenadeScene, s["handleScene"], s["throwPos"], s["throwRotY"],
        s["throwDir"], s["throwBasisX"], s["throwForce"],
    )


func _on_high_pre() -> void:
    var rig: Node3D = _lib._caller as Node3D
    if rig != null:
        _capture(rig, 30.0)


func _on_high_post() -> void:
    var rig: Node3D = _lib._caller as Node3D
    if rig != null:
        _broadcast(rig, "ThrowHigh")


func _on_low_pre() -> void:
    var rig: Node3D = _lib._caller as Node3D
    if rig != null:
        _capture(rig, 15.0)


func _on_low_post() -> void:
    var rig: Node3D = _lib._caller as Node3D
    if rig != null:
        _broadcast(rig, "ThrowLow")
