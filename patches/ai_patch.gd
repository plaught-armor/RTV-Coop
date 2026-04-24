## Patch for AI.gd — multi-player targeting, host-auth logic, remote damage routing.
extends "res://Scripts/AI.gd"

const PATH_AI: NodePath = ^"AI"




# -1 = host's local player; otherwise a remote peer ID.
var targetPeerId: int = -1

# True when borrowed as a remote-player puppet rig; skips all AI logic.
var puppetMode: bool = false


# Matches remote_player.gd COOP_HIT_LAYER (bit 19).
const COOP_HIT_LAYER: int = 1 << 19


func _ready() -> void:
    super._ready()
    if puppetMode:
        set_physics_process(false)
        set_process(false)
    if fire != null:
        fire.collision_mask |= COOP_HIT_LAYER
    if LOS != null:
        LOS.collision_mask |= COOP_HIT_LAYER


# Walks up instead of /root/Map so AI in headless SubViewports finds its map too.
func Initialize():
    await get_tree().physics_frame

    # Puppet rigs have already freed Agent/Detector/Raycasts/Poles/Gizmo/
    # Container/Backpacks/HB_* in remote_player.gd._spawn_puppet_rig, so
    # Deactivate*/HideGizmos here would iterate freed instances and crash.
    if puppetMode:
        return

    navigationMap = get_world_3d().get_navigation_map()
    var mapAncestor: Node = _find_map_ancestor()
    if mapAncestor != null:
        map = mapAncestor
        var aiNode: Node = mapAncestor.get_node_or_null(PATH_AI)
        if aiNode != null:
            AISpawner = aiNode
        else:
            push_warning("[ai_patch] Initialize: Map found (%s) but no AI child" % mapAncestor.get_path())
    else:
        push_warning("[ai_patch] Initialize: could not find map ancestor for %s" % get_path())

    if boss:
        health = 300.0
    else:
        health = 100.0

    DeactivateEquipment()
    DeactivateContainer()

    SelectWeapon()
    if allowBackpacks:
        SelectBackpack()
    if allowClothing:
        SelectClothing()

    HideGizmos()

    await get_tree().create_timer(10.0, false).timeout
    if !is_instance_valid(self):
        return

    voiceCycle = randf_range(10.0, 60.0)
    sensorActive = true


# Identifies map by AI child or SubViewport parent (robust to renamed scene roots).
func _find_map_ancestor() -> Node:
    var node: Node = self
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
        push_error("[ai_patch] _find_map_ancestor exceeded 64 hops; giving up")
    return null


func _physics_process(delta: float) -> void:
    if puppetMode:
        return
    if CoopManager.is_session_active():
        if !CoopManager.isHost:
            return
        # Skip gameData.isDead so AI stays active for surviving remotes after host dies.
        if pause || dead:
            return
        if sensorActive && !gameData.isFlying && !gameData.isCaching:
            if !_all_players_dead():
                Sensor(delta)
                Parameters(delta)
                FireDetection(delta)
        NearbyPoints(delta)
        Voices(delta)
        Interactor(delta)
        States(delta)
        Movement(delta)
        Rotation(delta)
        Poles()
        Animate(delta)
        return
    super._physics_process(delta)


# Per-frame cache: result identical across all AI in one tick.
var _allDeadCachedFrame: int = -1
var _allDeadCachedResult: bool = false


func _all_players_dead() -> bool:
    var frame: int = Engine.get_physics_frames()
    if _allDeadCachedFrame == frame:
        return _allDeadCachedResult
    _allDeadCachedFrame = frame
    if !gameData.isDead:
        _allDeadCachedResult = false
        return false
    for remote: Node3D in CoopManager.remoteNodes:
        if is_instance_valid(remote) && !remote.get_meta(&"is_dead", false):
            _allDeadCachedResult = false
            return false
    _allDeadCachedResult = true
    return true

func Parameters(delta: float) -> void:
    if !CoopManager.is_session_active():
        super.Parameters(delta)
        return
    var _pt: int = CoopManager.perf.start()

    LKL = lerp(LKL, lastKnownLocation, delta * LKLSpeed)

    # Host counts as a candidate only when alive AND not in a trader UI.
    var hostTargetable: bool = !gameData.isDead && !gameData.isTrading
    var bestPos: Vector3 = gameData.playerPosition
    var bestDist: float = global_position.distance_to(bestPos) if hostTargetable else INF
    var bestVector: Vector3 = gameData.playerVector
    targetPeerId = -1

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        if remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.TRADING):
            continue
        var pos: Vector3 = remote.global_position
        var dist: float = global_position.distance_to(pos)
        if dist < bestDist:
            bestDist = dist
            bestPos = pos
            targetPeerId = remote.get_meta(&"peer_id", -1)
            var rotY: float = remote.targetRotationY
            bestVector = Vector3(-sin(rotY), 0, -cos(rotY))

    playerPosition = bestPos
    playerDistance3D = bestDist
    playerDistance2D = Vector2(global_position.x, global_position.z).distance_to(
        Vector2(bestPos.x, bestPos.z))
    fireVector = (global_position - bestPos).normalized().dot(bestVector)

    var aggro: float = maxf(0.1, CoopManager.settings.get("ai_aggression_multiplier", 1.0))
    if playerDistance3D < 10 && playerVisible:
        sensorCycle = 0.05 / aggro
        LKLSpeed = 4.0 * aggro
    elif playerDistance3D > 10 && playerDistance3D < 50:
        sensorCycle = 0.1 / aggro
        LKLSpeed = 2.0 * aggro
    elif playerDistance3D > 50:
        sensorCycle = 0.5 / aggro
        LKLSpeed = 1.0 * aggro
    CoopManager.perf.stop("ai.Parameters", _pt)

func Sensor(delta: float) -> void:
    if !CoopManager.is_session_active():
        super.Sensor(delta)
        return
    var _pt: int = CoopManager.perf.start()
    sensorTimer += delta
    if sensorTimer > sensorCycle:
        if playerDistance3D <= 200.0:
            var targetCamPos: Vector3 = _get_target_camera_position()
            var directionToPlayer: Vector3 = (eyes.global_position - targetCamPos).normalized()
            var viewDirection: Vector3 = -eyes.global_transform.basis.z.normalized()
            var viewRadius: float = viewDirection.dot(directionToPlayer)

            if viewRadius > 0.5:
                LOSCheck(targetCamPos)
            else:
                playerVisible = false
        else:
            playerVisible = false

        if !playerVisible:
            Hearing()

        sensorTimer = 0.0
    CoopManager.perf.stop("ai.Sensor", _pt)


# Host local player uses gameData.cameraPosition; remotes approximate eye height at +1.6m.
func _get_target_camera_position() -> Vector3:
    if targetPeerId < 0:
        return gameData.cameraPosition
    var remote: Node3D = CoopManager.get_remote_player_node(targetPeerId)
    if !is_instance_valid(remote):
        return gameData.cameraPosition
    return remote.global_position + Vector3(0, 1.6, 0)

func LOSCheck(target: Vector3) -> void:
    var _pt: int = CoopManager.perf.start()
    if !CoopManager.is_session_active():
        CoopManager.perf.stop("ai.LOSCheck", _pt)
        super.LOSCheck(target)
        return

    if gameData.TOD == 4 && !gameData.flashlight && !boss:
        LOS.target_position = Vector3(0, 0, 25 + extraVisibility)
    elif gameData.fog && !boss:
        LOS.target_position = Vector3(0, 0, 100 + extraVisibility)
    else:
        LOS.target_position = Vector3(0, 0, 200)

    LOS.look_at(target, Vector3.UP, true)
    LOS.force_raycast_update()

    if LOS.is_colliding():
        var collider: Node = LOS.get_collider()
        if collider.is_in_group(&"Player") || collider.is_in_group(&"CoopRemote"):
            lastKnownLocation = playerPosition
            playerVisible = true

            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            elif currentState == State.Ambush:
                ChangeState("Combat")
            CoopManager.perf.stop("ai.LOSCheck", _pt)
            return

    playerVisible = false
    CoopManager.perf.stop("ai.LOSCheck", _pt)

func Hearing() -> void:
    if !CoopManager.is_session_active():
        super.Hearing()
        return

    if (playerDistance3D < 20 && gameData.isRunning) || (playerDistance3D < 5 && gameData.isWalking):
        if currentState != State.Ambush:
            lastKnownLocation = playerPosition
        if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
            Decision()
        return

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        var dist: float = global_position.distance_to(remote.global_position)
        var isRunning: bool = remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.RUNNING)
        var isWalking: bool = remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.WALKING)
        if (dist < 20 && isRunning) || (dist < 5 && isWalking):
            if currentState != State.Ambush:
                lastKnownLocation = remote.global_position
            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            return

func FireDetection(delta: float) -> void:
    if !CoopManager.is_session_active():
        super.FireDetection(delta)
        return
    var _pt: int = CoopManager.perf.start()

    if gameData.isFiring && !playerVisible:
        var hostDist: float = global_position.distance_to(gameData.playerPosition)
        var hostFireVec: float = (global_position - gameData.playerPosition).normalized().dot(gameData.playerVector)
        if hostFireVec > 0.95:
            lastKnownLocation = gameData.playerPosition
            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            elif currentState == State.Ambush:
                ChangeState("Combat")
            fireDetected = true
            extraVisibility = 50.0
        elif hostDist < 50:
            if currentState != State.Ambush:
                lastKnownLocation = gameData.playerPosition
            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            fireDetected = true
            extraVisibility = 50.0

    for remote: Node3D in CoopManager.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        if !remote.has_flag(CoopManager.PlayerStateScript.MoveFlag.FIRING):
            continue
        if playerVisible:
            continue
        var remoteDist: float = global_position.distance_to(remote.global_position)
        if remoteDist < 50:
            if currentState != State.Ambush:
                lastKnownLocation = remote.global_position
            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            fireDetected = true
            extraVisibility = 50.0

    if fireDetected:
        fireDetectionTimer += delta
        if fireDetectionTimer > fireDetectionTime:
            extraVisibility = 0.0
            fireDetectionTimer = 0.0
            fireDetected = false
    CoopManager.perf.stop("ai.FireDetection", _pt)

func Raycast() -> void:
    if !CoopManager.is_session_active():
        super.Raycast()
        return

    fire.look_at(FireAccuracy(), Vector3.UP, true)
    fire.force_raycast_update()

    if fire.is_colliding():
        var hitCollider: Node = fire.get_collider()
        if !is_instance_valid(hitCollider):
            return

        if hitCollider.is_in_group(&"CoopRemote"):
            var remoteRoot: Node3D = CoopManager.find_remote_root(hitCollider)
            if remoteRoot != null:
                var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
                if peerId > 0:
                    var dmgMul: float = CoopManager.settings.get("damage_to_player_multiplier", 1.0)
                    var dmg: float = weaponData.damage * (2.0 if boss else 1.0) * dmgMul
                    CoopManager.aiState.send_ai_damage_to_peer(peerId, dmg, weaponData.penetration)

        elif hitCollider.is_in_group(&"Player"):
            var dmgMul: float = CoopManager.settings.get("damage_to_player_multiplier", 1.0)
            var dmg: float = weaponData.damage * (2.0 if boss else 1.0) * dmgMul
            hitCollider.get_child(0).WeaponDamage(dmg, weaponData.penetration)

        else:
            var hitPoint: Vector3 = fire.get_collision_point()
            var hitNormal: Vector3 = fire.get_collision_normal()
            var hitSurface: Variant = hitCollider.get(&"surface")
            BulletDecal(hitCollider, hitPoint, hitNormal, hitSurface)

    elif playerDistance3D > 50:
        await get_tree().create_timer(0.1, false).timeout
        if !is_instance_valid(self):
            return
        PlayFlyby()

func Fire(delta: float) -> void:
    if !CoopManager.is_session_active():
        super.Fire(delta)
        return

    if impact || gameData.isTrading:
        return
    if LKL.distance_to(playerPosition) > 4.0:
        return
    if weaponData.weaponAction == "Semi-Auto":
        Selector(delta)

    fireTime -= delta
    if fireTime <= 0:
        Raycast()
        PlayFire()
        PlayTail()
        MuzzleVFX()

        impulseTime = spineData.impulse / 2
        impulseTimer = 0.0
        recoveryTime = spineData.impulse
        recoveryTimer = 0.0

        if fullAuto:
            var impulseX: float = spineTarget.x - spineData.recoil / 10.0
            impulseTarget = Vector3(impulseX, spineTarget.y, spineTarget.z)
        else:
            var impulseX: float = spineTarget.x - spineData.recoil
            impulseTarget = Vector3(impulseX, spineTarget.y, spineTarget.z)

        flash.global_position = muzzle.global_position
        flash.Activate()
        FireFrequency()

        if has_meta(&"ai_sync_id"):
            var syncId: int = get_meta(&"ai_sync_id")
            CoopManager.aiState.broadcast_ai_fire(syncId)

        if playerDistance3D > 50:
            await get_tree().create_timer(0.1, false).timeout
            if !is_instance_valid(self):
                return
            PlayCrack()

## Host applies damage locally; client routes to host via RPC.
func WeaponDamage(hitbox: String, damage: float) -> void:
    var scaledDamage: float = damage * CoopManager.settings.get("damage_to_ai_multiplier", 1.0)
    if !CoopManager.is_session_active():
        super.WeaponDamage(hitbox, scaledDamage)
        return
    if CoopManager.isHost:
        super.WeaponDamage(hitbox, scaledDamage)
        return
    if !has_meta(&"ai_sync_id"):
        return
    var syncId: int = get_meta(&"ai_sync_id")
    CoopManager.aiState.request_ai_damage_from_client.rpc_id(1, syncId, hitbox, scaledDamage)

const _AIStateScript: GDScript = preload("res://mod/network/ai_state.gd")


func PlayIdle() -> void:
    super.PlayIdle()
    _broadcast_voice(_AIStateScript.VoiceType.IDLE)


func PlayCombat() -> void:
    super.PlayCombat()
    _broadcast_voice(_AIStateScript.VoiceType.COMBAT)


func PlayDamage() -> void:
    super.PlayDamage()
    _broadcast_voice(_AIStateScript.VoiceType.DAMAGE)


# Puppet rigs have stripped Raycasts/Below; animation tracks still fire this
# via call-method. Skip to avoid freed-instance crash.
func PlayFootstep() -> void:
    if puppetMode:
        return
    super.PlayFootstep()


func _broadcast_voice(voiceType: int) -> void:
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    if !has_meta(&"ai_sync_id"):
        return
    CoopManager.aiState.broadcast_ai_voice(get_meta(&"ai_sync_id"), voiceType)


func Death(direction: Vector3, force: float) -> void:
    if CoopManager.is_session_active() && CoopManager.isHost:
        if has_meta(&"ai_sync_id"):
            var syncId: int = get_meta(&"ai_sync_id")
            CoopManager.aiState.broadcast_ai_death(syncId, direction, force)
    super.Death(direction, force)


## Broadcasts AI-triggered door opens; AI only runs on host so this is the sync point.
func Interactor(delta: float) -> void:
    # Snapshot before super so fresh-open detection has something to compare.
    # Duck-type Door via `isOpen` prop: `is Door` breaks if Door.gd gets take_over_path'd later.
    var doorBefore: Node = null
    if is_instance_valid(forward) && forward.is_colliding():
        var hit: Node = forward.get_collider()
        if is_instance_valid(hit) && hit.is_in_group(&"Interactable") && hit.owner != null && hit.owner.get(&"isOpen") != null:
            if !hit.owner.isOpen && !hit.owner.locked && !hit.owner.jammed:
                doorBefore = hit.owner

    super.Interactor(delta)

    if !is_instance_valid(doorBefore):
        return
    if !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    if doorBefore.isOpen:
        var doorPath: String = get_tree().current_scene.get_path_to(doorBefore)
        CoopManager.worldState.sync_door_state.rpc(doorPath, true)
        if CoopManager.DEBUG:
            print("[ai_patch] AI opened door %s — broadcast" % doorPath)
