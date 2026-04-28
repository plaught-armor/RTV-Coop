## Patch for Explosion.gd — co-op splash damage (host-authoritative, remote player detection).
extends "res://Scripts/Explosion.gd"


# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")

const COOP_HIT_LAYER: int = 1 << 19


func Explode() -> void:
    if CoopManager.is_session_active():
        area.collision_mask |= COOP_HIT_LAYER
        CoopManager._log("[explosion] Explode pos=%s host=%s" % [str(global_position), str(CoopManager.isHost)])
    super.Explode()


func CheckOverlap() -> void:
    if !CoopManager.is_session_active():
        super.CheckOverlap()
        return

    var bodies: Array[Node3D] = area.get_overlapping_bodies()
    if bodies.size() == 0:
        return

    CoopManager._log("[explosion] CheckOverlap bodies=%d" % bodies.size())
    for target: Node3D in bodies:
        if target.is_in_group(&"CoopRemote"):
            _check_los_remote(target)
        elif target.get(&"head") != null:
            CheckLOS(target)


func CheckLOS(target) -> void:
    if !CoopManager.is_session_active():
        super.CheckLOS(target)
        return

    LOS.look_at(target.head.global_position, Vector3.UP, true)
    LOS.force_raycast_update()

    if !LOS.is_colliding():
        return

    var collider: Node = LOS.get_collider()

    # Host-only: client-side AI damage would be overwritten by next AIState snapshot (desync).
    if !CoopManager.isHost:
        return

    if collider.is_in_group(&"AI"):
        CoopManager._log("[explosion] AI damage to %s" % target.name)
        target.ExplosionDamage(LOS.global_basis.z)
    elif collider.is_in_group(&"Player"):
        CoopManager._log("[explosion] Player damage to %s" % target.name)
        target.get_child(0).ExplosionDamage()


func _check_los_remote(target: Node3D) -> void:
    if !CoopManager.isHost:
        return

    var eyePos: Vector3 = target.global_position + Vector3(0, 1.6, 0)
    LOS.look_at(eyePos, Vector3.UP, true)
    LOS.force_raycast_update()

    if !LOS.is_colliding():
        return

    var collider: Node = LOS.get_collider()
    if collider.is_in_group(&"CoopRemote"):
        var remoteRoot: Node3D = CoopManager.find_remote_root(collider)
        if remoteRoot != null:
            var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
            if peerId > 0:
                CoopManager._log("[explosion] remote peer=%d damage" % peerId)
                CoopManager.aiState.send_explosion_damage_to_peer(peerId)


