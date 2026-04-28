## Hook callbacks for KnifeRig.gd — broadcasts slash/stab audio + hit decals to remotes.
## Replaces patches/knife_rig_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("kniferig-slashaudio-post", _on_slash_audio)
    lib.hook("kniferig-stabaudio-post", _on_stab_audio)
    lib.hook("kniferig-hitcheck-post", _on_hit_check)


func _on_slash_audio() -> void:
    if !CoopManager.is_session_active():
        return
    var rig: Knife = _lib._caller as Knife
    if rig == null:
        return
    CoopManager.playerState.broadcast_knife_attack(true, rig.attack)


func _on_stab_audio() -> void:
    if !CoopManager.is_session_active():
        return
    var rig: Knife = _lib._caller as Knife
    if rig == null:
        return
    CoopManager.playerState.broadcast_knife_attack(false, rig.attack)


func _on_hit_check() -> void:
    if !CoopManager.is_session_active():
        return
    var rig: Knife = _lib._caller as Knife
    if rig == null:
        return
    var raycast: RayCast3D = rig.raycast
    if !raycast.is_colliding():
        return
    var collider: Object = raycast.get_collider()
    var hitSurface: Variant = collider.get(&"surface")
    var surfaceStr: String = str(hitSurface) if hitSurface != null else ""
    CoopManager._log("[knife] HitCheck surface=%s hitbox=%s attack=%d" % [surfaceStr, str(collider is Hitbox), rig.attack])
    CoopManager.playerState.broadcast_knife_hit(
        raycast.get_collision_point(),
        raycast.get_collision_normal(),
        surfaceStr,
        collider is Hitbox,
        rig.attack,
    )
