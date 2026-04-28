## Hook callbacks for AI.gd — multi-player targeting, host-auth logic, remote damage routing.
## Replaces patches/ai_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Per-instance state: targetPeerId + Interactor doorBefore in dicts keyed by AI node.
extends RefCounted


const PATH_AI: NodePath = ^"AI"
# Matches remote_player.gd COOP_HIT_LAYER (bit 19).
const COOP_HIT_LAYER: int = 1 << 19

var _lib: Object = null
var _targetPeerId: Dictionary[Node, int] = {}
# Captured door reference between ai-interactor-pre and -post (vanilla mutates state).
var _doorBefore: Dictionary[Node, Node] = {}
# Per-frame cache: result identical across all AI in one tick.
var _allDeadCachedFrame: int = -1
var _allDeadCachedResult: bool = false


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("ai-_ready-post", _on_ready_post)
    lib.hook("ai-initialize", _on_initialize)
    lib.hook("ai-_physics_process", _on_physics_process)
    lib.hook("ai-parameters", _on_parameters)
    lib.hook("ai-sensor", _on_sensor)
    lib.hook("ai-loscheck", _on_los_check)
    lib.hook("ai-hearing", _on_hearing)
    lib.hook("ai-firedetection", _on_fire_detection)
    lib.hook("ai-raycast", _on_raycast)
    lib.hook("ai-fire", _on_fire)
    lib.hook("ai-weapondamage", _on_weapon_damage)
    lib.hook("ai-playidle-post", _on_play_idle_post)
    lib.hook("ai-playcombat-post", _on_play_combat_post)
    lib.hook("ai-playdamage-post", _on_play_damage_post)
    lib.hook("ai-death-pre", _on_death_pre)
    lib.hook("ai-interactor-pre", _on_interactor_pre)
    lib.hook("ai-interactor-post", _on_interactor_post)


func _on_ready_post() -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if ai.fire != null:
        ai.fire.collision_mask |= COOP_HIT_LAYER
    if ai.LOS != null:
        ai.LOS.collision_mask |= COOP_HIT_LAYER


func _on_initialize() -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    _lib.skip_super()
    CoopManager._log("[ai.trace] Initialize ENTER name=%s" % ai.name)
    await ai.get_tree().physics_frame
    if !is_instance_valid(ai):
        CoopManager._log("[ai.trace] Initialize ai freed during physics_frame await — bail")
        return

    ai.navigationMap = ai.get_world_3d().get_navigation_map()
    var mapAncestor: Node = _find_map_ancestor(ai)
    if mapAncestor != null:
        ai.map = mapAncestor
        var aiNode: Node = mapAncestor.get_node_or_null(PATH_AI)
        if aiNode != null:
            ai.AISpawner = aiNode
        else:
            push_warning("[ai_hooks] Initialize: Map found (%s) but no AI child" % mapAncestor.get_path())
    else:
        push_warning("[ai_hooks] Initialize: could not find map ancestor for %s" % ai.get_path())

    if ai.boss:
        ai.health = 300.0
    else:
        ai.health = 100.0

    ai.DeactivateEquipment()
    ai.DeactivateContainer()

    if !CoopManager.is_session_active() || CoopManager.isHost:
        ai.SelectWeapon()
        if ai.allowBackpacks:
            ai.SelectBackpack()
        if ai.allowClothing:
            ai.SelectClothing()
        if CoopManager.is_session_active() && CoopManager.isHost && ai.has_meta(&"ai_sync_id"):
            CoopManager.aiState.broadcast_ai_loadout(ai.get_meta(&"ai_sync_id"), ai)

    ai.HideGizmos()

    if CoopManager.is_session_active() && !CoopManager.isHost:
        return

    await ai.get_tree().create_timer(10.0, false).timeout
    if !is_instance_valid(ai):
        return

    ai.voiceCycle = randf_range(10.0, 60.0)
    ai.sensorActive = true


func _find_map_ancestor(ai: Node) -> Node:
    var node: Node = ai
    var depth: int = 0
    while node != null && depth < 64:
        if node.get_node_or_null(PATH_AI) != null:
            return node
        var parent: Node = node.get_parent()
        if parent is SubViewport:
            return node
        node = parent
        depth += 1
    if depth >= 64:
        push_error("[ai_hooks] _find_map_ancestor exceeded 64 hops; giving up")
    return null


func _on_physics_process(delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla _physics_process runs.
    _lib.skip_super()
    if !CoopManager.isHost:
        # Client: animate only — host owns FSM/Sensor/Movement.
        if !ai.has_meta(&"_ai_advance_logged"):
            ai.set_meta(&"_ai_advance_logged", true)
            CoopManager._log("[ai_hooks] client advance start name=%s animator=%s active=%s" % [ai.name, str(ai.animator != null), str(ai.animator != null && ai.animator.active)])
        if ai.animator != null && ai.animator.active:
            ai.animator.advance(delta)
            if ai.skeleton != null:
                ai.skeleton.advance(delta)
        return
    # Skip gameData.isDead so AI stays active for surviving remotes after host dies.
    if ai.pause || ai.dead:
        return
    if ai.sensorActive && !ai.gameData.isFlying && !ai.gameData.isCaching:
        if !_all_players_dead(ai):
            ai.Sensor(delta)
            ai.Parameters(delta)
            ai.FireDetection(delta)
    ai.NearbyPoints(delta)
    ai.Voices(delta)
    ai.Interactor(delta)
    ai.States(delta)
    ai.Movement(delta)
    ai.Rotation(delta)
    ai.Poles()
    ai.Animate(delta)


func _all_players_dead(ai: Node) -> bool:
    var frame: int = Engine.get_physics_frames()
    if _allDeadCachedFrame == frame:
        return _allDeadCachedResult
    _allDeadCachedFrame = frame
    if !ai.gameData.isDead:
        _allDeadCachedResult = false
        return false
    for remote: Node3D in CoopManager.remoteNodes:
        if is_instance_valid(remote) && !remote.get_meta(&"is_dead", false):
            _allDeadCachedResult = false
            return false
    _allDeadCachedResult = true
    return true


func _on_parameters(delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()
    var _pt: int = CoopManager.perf.start()

    ai.LKL = lerp(ai.LKL, ai.lastKnownLocation, delta * ai.LKLSpeed)

    var hostTargetable: bool = !ai.gameData.isDead && !ai.gameData.isTrading
    var bestPos: Vector3 = ai.gameData.playerPosition
    var bestDist: float = ai.global_position.distance_to(bestPos) if hostTargetable else INF
    var bestVector: Vector3 = ai.gameData.playerVector
    var localTarget: int = -1

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        if remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.TRADING):
            continue
        var pos: Vector3 = remote.global_position
        var dist: float = ai.global_position.distance_to(pos)
        if dist < bestDist:
            bestDist = dist
            bestPos = pos
            localTarget = remote.get_meta(&"peer_id", -1)
            var rotY: float = remote.targetRotationY
            bestVector = Vector3(-sin(rotY), 0, -cos(rotY))

    _targetPeerId[ai] = localTarget
    ai.playerPosition = bestPos
    ai.playerDistance3D = bestDist
    ai.playerDistance2D = Vector2(ai.global_position.x, ai.global_position.z).distance_to(
        Vector2(bestPos.x, bestPos.z))
    ai.fireVector = (ai.global_position - bestPos).normalized().dot(bestVector)

    var aggro: float = maxf(0.1, CoopManager.settings.get("ai_aggression_multiplier", 1.0))
    if ai.playerDistance3D < 10 && ai.playerVisible:
        ai.sensorCycle = 0.05 / aggro
        ai.LKLSpeed = 4.0 * aggro
    elif ai.playerDistance3D > 10 && ai.playerDistance3D < 50:
        ai.sensorCycle = 0.1 / aggro
        ai.LKLSpeed = 2.0 * aggro
    elif ai.playerDistance3D > 50:
        ai.sensorCycle = 0.5 / aggro
        ai.LKLSpeed = 1.0 * aggro
    CoopManager.perf.stop("ai.Parameters", _pt)


func _on_sensor(delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()
    var _pt: int = CoopManager.perf.start()
    ai.sensorTimer += delta
    if ai.sensorTimer > ai.sensorCycle:
        if ai.playerDistance3D <= 200.0:
            var targetCamPos: Vector3 = _get_target_camera_position(ai)
            var directionToPlayer: Vector3 = (ai.eyes.global_position - targetCamPos).normalized()
            var viewDirection: Vector3 = -ai.eyes.global_transform.basis.z.normalized()
            var viewRadius: float = viewDirection.dot(directionToPlayer)

            if viewRadius > 0.5:
                ai.LOSCheck(targetCamPos)
            else:
                ai.playerVisible = false
        else:
            ai.playerVisible = false

        if !ai.playerVisible:
            ai.Hearing()

        ai.sensorTimer = 0.0
    CoopManager.perf.stop("ai.Sensor", _pt)


func _get_target_camera_position(ai: Node) -> Vector3:
    var pid: int = _targetPeerId.get(ai, -1)
    if pid < 0:
        return ai.gameData.cameraPosition
    var remote: Node3D = CoopManager.get_remote_player_node(pid)
    if !is_instance_valid(remote):
        return ai.gameData.cameraPosition
    return remote.global_position + Vector3(0, 1.6, 0)


func _on_los_check(target: Vector3) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    var _pt: int = CoopManager.perf.start()
    if !CoopManager.is_session_active():
        CoopManager.perf.stop("ai.LOSCheck", _pt)
        return  # vanilla runs.
    _lib.skip_super()

    if ai.gameData.TOD == 4 && !ai.gameData.flashlight && !ai.boss:
        ai.LOS.target_position = Vector3(0, 0, 25 + ai.extraVisibility)
    elif ai.gameData.fog && !ai.boss:
        ai.LOS.target_position = Vector3(0, 0, 100 + ai.extraVisibility)
    else:
        ai.LOS.target_position = Vector3(0, 0, 200)

    ai.LOS.look_at(target, Vector3.UP, true)
    ai.LOS.force_raycast_update()

    if ai.LOS.is_colliding():
        var collider: Node = ai.LOS.get_collider()
        if collider.is_in_group(&"Player") || collider.is_in_group(&"CoopRemote"):
            ai.lastKnownLocation = ai.playerPosition
            ai.playerVisible = true

            if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
                ai.Decision()
            elif ai.currentState == ai.State.Ambush:
                ai.ChangeState("Combat")
            CoopManager.perf.stop("ai.LOSCheck", _pt)
            return

    ai.playerVisible = false
    CoopManager.perf.stop("ai.LOSCheck", _pt)


func _on_hearing() -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()

    if (ai.playerDistance3D < 20 && ai.gameData.isRunning) || (ai.playerDistance3D < 5 && ai.gameData.isWalking):
        if ai.currentState != ai.State.Ambush:
            ai.lastKnownLocation = ai.playerPosition
        if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
            ai.Decision()
        return

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        var dist: float = ai.global_position.distance_to(remote.global_position)
        var isRunning: bool = remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.RUNNING)
        var isWalking: bool = remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.WALKING)
        if (dist < 20 && isRunning) || (dist < 5 && isWalking):
            if ai.currentState != ai.State.Ambush:
                ai.lastKnownLocation = remote.global_position
            if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
                ai.Decision()
            return


func _on_fire_detection(delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()
    var _pt: int = CoopManager.perf.start()

    if ai.gameData.isFiring && !ai.playerVisible:
        var hostDist: float = ai.global_position.distance_to(ai.gameData.playerPosition)
        var hostFireVec: float = (ai.global_position - ai.gameData.playerPosition).normalized().dot(ai.gameData.playerVector)
        if hostFireVec > 0.95:
            ai.lastKnownLocation = ai.gameData.playerPosition
            if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
                ai.Decision()
            elif ai.currentState == ai.State.Ambush:
                ai.ChangeState("Combat")
            ai.fireDetected = true
            ai.extraVisibility = 50.0
        elif hostDist < 50:
            if ai.currentState != ai.State.Ambush:
                ai.lastKnownLocation = ai.gameData.playerPosition
            if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
                ai.Decision()
            ai.fireDetected = true
            ai.extraVisibility = 50.0

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        if !remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.FIRING):
            continue
        if ai.playerVisible:
            continue
        var remoteDist: float = ai.global_position.distance_to(remote.global_position)
        if remoteDist < 50:
            if ai.currentState != ai.State.Ambush:
                ai.lastKnownLocation = remote.global_position
            if ai.currentState == ai.State.Wander || ai.currentState == ai.State.Guard || ai.currentState == ai.State.Patrol:
                ai.Decision()
            ai.fireDetected = true
            ai.extraVisibility = 50.0

    if ai.fireDetected:
        ai.fireDetectionTimer += delta
        if ai.fireDetectionTimer > ai.fireDetectionTime:
            ai.extraVisibility = 0.0
            ai.fireDetectionTimer = 0.0
            ai.fireDetected = false
    CoopManager.perf.stop("ai.FireDetection", _pt)


func _on_raycast() -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()

    ai.fire.look_at(ai.FireAccuracy(), Vector3.UP, true)
    ai.fire.force_raycast_update()

    if ai.fire.is_colliding():
        var hitCollider: Node = ai.fire.get_collider()
        if !is_instance_valid(hitCollider):
            return

        if hitCollider.is_in_group(&"CoopRemote"):
            var remoteRoot: Node3D = CoopManager.find_remote_root(hitCollider)
            if remoteRoot != null:
                var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
                if peerId > 0:
                    var dmgMul: float = CoopManager.settings.get("damage_to_player_multiplier", 1.0)
                    var dmg: float = ai.weaponData.damage * (2.0 if ai.boss else 1.0) * dmgMul
                    CoopManager.aiState.send_ai_damage_to_peer(peerId, dmg, ai.weaponData.penetration)

        elif hitCollider.is_in_group(&"Player"):
            var dmgMul: float = CoopManager.settings.get("damage_to_player_multiplier", 1.0)
            var dmg: float = ai.weaponData.damage * (2.0 if ai.boss else 1.0) * dmgMul
            hitCollider.get_child(0).WeaponDamage(dmg, ai.weaponData.penetration)

        else:
            var hitPoint: Vector3 = ai.fire.get_collision_point()
            var hitNormal: Vector3 = ai.fire.get_collision_normal()
            var hitSurface: Variant = hitCollider.get(&"surface")
            ai.BulletDecal(hitCollider, hitPoint, hitNormal, hitSurface)

    elif ai.playerDistance3D > 50:
        await ai.get_tree().create_timer(0.1, false).timeout
        if !is_instance_valid(ai):
            return
        ai.PlayFlyby()


func _on_fire(delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla runs.
    _lib.skip_super()

    if ai.impact || ai.gameData.isTrading:
        return
    if ai.LKL.distance_to(ai.playerPosition) > 4.0:
        return
    if ai.weaponData.weaponAction == "Semi-Auto":
        ai.Selector(delta)

    ai.fireTime -= delta
    if ai.fireTime <= 0:
        ai.Raycast()
        ai.PlayFire()
        ai.PlayTail()
        ai.MuzzleVFX()

        ai.impulseTime = ai.spineData.impulse / 2
        ai.impulseTimer = 0.0
        ai.recoveryTime = ai.spineData.impulse
        ai.recoveryTimer = 0.0

        if ai.fullAuto:
            var impulseX: float = ai.spineTarget.x - ai.spineData.recoil / 10.0
            ai.impulseTarget = Vector3(impulseX, ai.spineTarget.y, ai.spineTarget.z)
        else:
            var impulseX: float = ai.spineTarget.x - ai.spineData.recoil
            ai.impulseTarget = Vector3(impulseX, ai.spineTarget.y, ai.spineTarget.z)

        ai.flash.global_position = ai.muzzle.global_position
        ai.flash.Activate()
        ai.FireFrequency()

        if ai.has_meta(&"ai_sync_id"):
            var syncId: int = ai.get_meta(&"ai_sync_id")
            CoopManager.aiState.broadcast_ai_fire(syncId)

        if ai.playerDistance3D > 50:
            await ai.get_tree().create_timer(0.1, false).timeout
            if !is_instance_valid(ai):
                return
            ai.PlayCrack()


## Host applies damage locally (scaled); client routes to host via RPC.
## Replace hook reimplements vanilla body so the scaled damage reaches health subtraction.
func _on_weapon_damage(hitbox: String, damage: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    _lib.skip_super()
    var scaledDamage: float = damage * CoopManager.settings.get("damage_to_ai_multiplier", 1.0)
    if !CoopManager.is_session_active() || CoopManager.isHost:
        _apply_weapon_damage(ai, hitbox, scaledDamage)
        return
    if !ai.has_meta(&"ai_sync_id"):
        return
    var syncId: int = ai.get_meta(&"ai_sync_id")
    CoopManager.aiState.request_ai_damage_from_client.rpc_id(1, syncId, hitbox, scaledDamage)


# Mirror of vanilla AI.WeaponDamage so scaled damage reaches health subtraction
# without a second wrapper round-trip via `ai.WeaponDamage(...)`.
func _apply_weapon_damage(ai: Node, hitbox: String, damage: float) -> void:
    if ai.dead:
        return
    ai.health -= damage
    ai.impact = true
    ai.impulseTime = ai.spineData.impulse
    ai.impulseTimer = 0.0
    ai.recoveryTime = ai.spineData.impulse
    ai.recoveryTimer = 0.0
    if hitbox == "Head" || hitbox == "Torso":
        var iX: float = randf_range(ai.spineTarget.x - ai.spineData.impact / 2, ai.spineTarget.x - ai.spineData.impact)
        var iY: float = randf_range(ai.spineTarget.y - ai.spineData.impact, ai.spineTarget.y + ai.spineData.impact)
        var iZ: float = randf_range(ai.spineTarget.z - ai.spineData.impact, ai.spineTarget.z + ai.spineData.impact)
        ai.impulseTarget = Vector3(iX, iY, iZ)
    elif hitbox == "Leg_L":
        var iX: float = randf_range(ai.spineTarget.x + ai.spineData.impact / 2, ai.spineTarget.x + ai.spineData.impact)
        var iY: float = randf_range(ai.spineTarget.y + ai.spineData.impact / 2, ai.spineTarget.y + ai.spineData.impact)
        var iZ: float = randf_range(ai.spineTarget.z - ai.spineData.impact, ai.spineTarget.z + ai.spineData.impact)
        ai.impulseTarget = Vector3(iX, iY, iZ)
    elif hitbox == "Leg_R":
        var iX: float = randf_range(ai.spineTarget.x + ai.spineData.impact / 2, ai.spineTarget.x + ai.spineData.impact)
        var iY: float = randf_range(ai.spineTarget.y - ai.spineData.impact / 2, ai.spineTarget.y - ai.spineData.impact)
        var iZ: float = randf_range(ai.spineTarget.z - ai.spineData.impact, ai.spineTarget.z + ai.spineData.impact)
        ai.impulseTarget = Vector3(iX, iY, iZ)
    if ai.health <= 0:
        if is_instance_valid(ai.activeVoice):
            ai.activeVoice.queue_free()
            ai.activeVoice = null
        if hitbox != "Head":
            ai.PlayDeath()
        ai.Death(ai.gameData.playerVector, 40)
    else:
        if !is_instance_valid(ai.activeVoice):
            ai.PlayDamage()


func _on_play_idle_post() -> void:
    _broadcast_voice(_lib._caller as CharacterBody3D, CoopManager.aiState.VoiceType.IDLE)


func _on_play_combat_post() -> void:
    _broadcast_voice(_lib._caller as CharacterBody3D, CoopManager.aiState.VoiceType.COMBAT)


func _on_play_damage_post() -> void:
    _broadcast_voice(_lib._caller as CharacterBody3D, CoopManager.aiState.VoiceType.DAMAGE)


func _broadcast_voice(ai: CharacterBody3D, voiceType: int) -> void:
    if ai == null:
        return
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    if !ai.has_meta(&"ai_sync_id"):
        return
    CoopManager.aiState.broadcast_ai_voice(ai.get_meta(&"ai_sync_id"), voiceType)


func _on_death_pre(_direction: Vector3, _force: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    if !ai.has_meta(&"ai_sync_id"):
        return
    var syncId: int = ai.get_meta(&"ai_sync_id")
    CoopManager._log("[ai_hooks] Death name=%s syncId=%d weapon=%s backpack=%s secondary=%s" % [ai.name, syncId, str(ai.weapon != null), str(ai.backpack != null), str(ai.secondary != null)])
    CoopManager.aiState.broadcast_ai_death(syncId, _direction, _force)
    _register_corpse_items_as_synced(ai, syncId)


## Tag the AI's weapon/backpack/secondary RigidBodies with deterministic
## sync_ids derived from [param syncId] and register them in
## [member world_state.syncedItems] so the existing pickup-broadcast path works.
func _register_corpse_items_as_synced(ai: CharacterBody3D, syncId: int) -> void:
    var ws: Node = CoopManager.worldState
    if !is_instance_valid(ws):
        return
    var corpseId: int = syncId * 10
    _maybe_register(ws, ai.weapon, "ai_corpse_%d_weapon" % corpseId)
    _maybe_register(ws, ai.backpack, "ai_corpse_%d_backpack" % corpseId)
    _maybe_register(ws, ai.secondary, "ai_corpse_%d_secondary" % corpseId)


func _maybe_register(ws: Node, item: Variant, syncId: String) -> void:
    if !(item is Node) || !is_instance_valid(item):
        return
    var node: Node = item as Node
    node.set_meta(&"sync_id", syncId)
    ws.syncedItems[syncId] = node


func _on_interactor_pre(_delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    var doorBefore: Node = null
    if is_instance_valid(ai.forward) && ai.forward.is_colliding():
        var hit: Node = ai.forward.get_collider()
        if is_instance_valid(hit) && hit.is_in_group(&"Interactable") && hit.owner != null && hit.owner.get(&"isOpen") != null:
            if !hit.owner.isOpen && !hit.owner.locked && !hit.owner.jammed:
                doorBefore = hit.owner
    _doorBefore[ai] = doorBefore


func _on_interactor_post(_delta: float) -> void:
    var ai: CharacterBody3D = _lib._caller as CharacterBody3D
    if ai == null:
        return
    var doorBefore: Node = _doorBefore.get(ai, null)
    _doorBefore.erase(ai)
    if !is_instance_valid(doorBefore):
        return
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    if doorBefore.isOpen:
        var doorPath: String = ai.get_tree().current_scene.get_path_to(doorBefore)
        CoopManager.worldState.sync_door_state.rpc(doorPath, true)
        if CoopManager.DEBUG:
            print("[ai_hooks] AI opened door %s — broadcast" % doorPath)
