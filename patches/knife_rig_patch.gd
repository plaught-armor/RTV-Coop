## Patch for KnifeRig.gd — broadcasts slash/stab audio and hit decals to remotes.
extends "res://Scripts/KnifeRig.gd"

var _cm: Node


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


func SlashAudio() -> void:
    super.SlashAudio()
    if _ensure_cm() && _cm.is_session_active():
        _cm.playerState.broadcast_knife_attack(true, attack)


func StabAudio() -> void:
    super.StabAudio()
    if _ensure_cm() && _cm.is_session_active():
        _cm.playerState.broadcast_knife_attack(false, attack)


func HitCheck() -> void:
    super.HitCheck()
    if !_ensure_cm() || !_cm.is_session_active():
        return
    if !raycast.is_colliding():
        return
    var collider: Object = raycast.get_collider()
    var hitSurface: Variant = collider.get(&"surface")
    var surfaceStr: String = str(hitSurface) if hitSurface != null else ""
    _cm.playerState.broadcast_knife_hit(
        raycast.get_collision_point(),
        raycast.get_collision_normal(),
        surfaceStr,
        collider is Hitbox,
        attack,
    )
