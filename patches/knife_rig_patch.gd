## Patch for [code]KnifeRig.gd[/code] — broadcasts knife attacks for co-op sync.
##
## Overrides:
## [br]- [method SlashAudio]: broadcasts slash event to remote peers
## [br]- [method StabAudio]: broadcasts stab event to remote peers
## [br]- [method HitCheck]: broadcasts hit impact to remote peers
##
## Remote players hear the slash/stab audio spatially and see knife
## hit decals. Original behaviour preserved when not in a co-op session.
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
    _ensure_cm()
    # Capture raycast data before super consumes it
    var wasColliding: bool = raycast.is_colliding()
    var hitPoint: Vector3 = Vector3.ZERO
    var hitNormal: Vector3 = Vector3.ZERO
    var hitSurface: Variant = null
    var isFlesh: bool = false
    if wasColliding:
        hitPoint = raycast.get_collision_point()
        hitNormal = raycast.get_collision_normal()
        hitSurface = raycast.get_collider().get(&"surface")
        isFlesh = raycast.get_collider() is Hitbox

    super.HitCheck()

    if wasColliding && is_instance_valid(_cm) && _cm.is_session_active():
        var surfaceStr: String = str(hitSurface) if hitSurface != null else ""
        _cm.playerState.broadcast_knife_hit(hitPoint, hitNormal, surfaceStr, isFlesh, attack)
