## Patch for KnifeRig.gd — broadcasts slash/stab audio and hit decals to remotes.
extends "res://Scripts/KnifeRig.gd"



func SlashAudio() -> void:
    super.SlashAudio()
    if CoopManager.is_session_active():
        CoopManager.playerState.broadcast_knife_attack(true, attack)


func StabAudio() -> void:
    super.StabAudio()
    if CoopManager.is_session_active():
        CoopManager.playerState.broadcast_knife_attack(false, attack)


func HitCheck() -> void:
    super.HitCheck()
    if !CoopManager.is_session_active():
        return
    if !raycast.is_colliding():
        return
    var collider: Object = raycast.get_collider()
    var hitSurface: Variant = collider.get(&"surface")
    var surfaceStr: String = str(hitSurface) if hitSurface != null else ""
    CoopManager.playerState.broadcast_knife_hit(
        raycast.get_collision_point(),
        raycast.get_collision_normal(),
        surfaceStr,
        collider is Hitbox,
        attack,
    )
