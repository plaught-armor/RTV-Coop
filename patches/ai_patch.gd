## Patch for AI.gd — multi-player targeting, host-auth logic, remote damage routing.
extends "res://Scripts/AI.gd"

const PATH_AI: NodePath = ^"AI"


var _cm: Node

# -1 = host's local player; otherwise a remote peer ID.
var targetPeerId: int = -1

# True when borrowed as a remote-player puppet rig; skips all AI logic.
var puppetMode: bool = false


# Matches remote_player.gd COOP_HIT_LAYER (bit 19).
const COOP_HIT_LAYER: int = 1 << 19


func init_manager(manager: Node) -> void:
    _cm = manager
    if fire != null:
        fire.collision_mask |= COOP_HIT_LAYER
    if LOS != null:
        LOS.collision_mask |= COOP_HIT_LAYER


func _ready() -> void:
    super._ready()
    if puppetMode:
        set_physics_process(false)
        set_process(false)
    if _cm == null:
        var root: Node = get_tree().root if get_tree() != null else null
        if root != null:
            for child: Node in root.get_children():
                if child.has_meta(&"is_coop_manager"):
                    _cm = child
                    break


# Walks up instead of /root/Map so AI in headless SubViewports finds its map too.
func Initialize():
    await get_tree().physics_frame

    if puppetMode:
        DeactivateEquipment()
        DeactivateContainer()
        HideGizmos()
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
    if is_instance_valid(_cm) && _cm.is_session_active():
        if !_cm.isHost:
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
    for remote: Node3D in _cm.remoteNodes:
        if is_instance_valid(remote) && !remote.get_meta(&"is_dead", false):
            _allDeadCachedResult = false
            return false
    _allDeadCachedResult = true
    return true

func Parameters(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Parameters(delta)
        return
    var _pt: int = _cm.perf.start()

    LKL = lerp(LKL, lastKnownLocation, delta * LKLSpeed)

    var bestPos: Vector3 = gameData.playerPosition
    var bestDist: float = global_position.distance_to(bestPos)
    var bestVector: Vector3 = gameData.playerVector
    targetPeerId = -1

    for remote: Node3D in _cm.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
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

    if playerDistance3D < 10 && playerVisible:
        sensorCycle = 0.05
        LKLSpeed = 4.0
    elif playerDistance3D > 10 && playerDistance3D < 50:
        sensorCycle = 0.1
        LKLSpeed = 2.0
    elif playerDistance3D > 50:
        sensorCycle = 0.5
        LKLSpeed = 1.0
    _cm.perf.stop("ai.Parameters", _pt)

func Sensor(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Sensor(delta)
        return
    var _pt: int = _cm.perf.start()
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
    _cm.perf.stop("ai.Sensor", _pt)


# Host local player uses gameData.cameraPosition; remotes approximate eye height at +1.6m.
func _get_target_camera_position() -> Vector3:
    if targetPeerId < 0:
        return gameData.cameraPosition
    var remote: Node3D = _cm.get_remote_player_node(targetPeerId)
    if !is_instance_valid(remote):
        return gameData.cameraPosition
    return remote.global_position + Vector3(0, 1.6, 0)

func LOSCheck(target: Vector3) -> void:
    var _pt: int = _cm.perf.start()
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        _cm.perf.stop("ai.LOSCheck", _pt)
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
            _cm.perf.stop("ai.LOSCheck", _pt)
            return

    playerVisible = false
    _cm.perf.stop("ai.LOSCheck", _pt)

func Hearing() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Hearing()
        return

    if (playerDistance3D < 20 && gameData.isRunning) || (playerDistance3D < 5 && gameData.isWalking):
        if currentState != State.Ambush:
            lastKnownLocation = playerPosition
        if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
            Decision()
        return

    for remote: Node3D in _cm.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        var dist: float = global_position.distance_to(remote.global_position)
        var flags: int = remote.moveFlags
        var isRunning: bool = (flags & _cm.PlayerStateScript.MoveFlag.RUNNING) != 0
        var isWalking: bool = (flags & _cm.PlayerStateScript.MoveFlag.WALKING) != 0
        if (dist < 20 && isRunning) || (dist < 5 && isWalking):
            if currentState != State.Ambush:
                lastKnownLocation = remote.global_position
            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            return

func FireDetection(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.FireDetection(delta)
        return
    var _pt: int = _cm.perf.start()

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

    for remote: Node3D in _cm.remoteNodes:
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        if !remote.isFiring:
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
    _cm.perf.stop("ai.FireDetection", _pt)

func Raycast() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Raycast()
        return

    fire.look_at(FireAccuracy(), Vector3.UP, true)
    fire.force_raycast_update()

    if fire.is_colliding():
        var hitCollider: Node = fire.get_collider()

        if hitCollider.is_in_group(&"CoopRemote"):
            var remoteRoot: Node3D = _cm.find_remote_root(hitCollider)
            if remoteRoot != null:
                var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
                if peerId > 0:
                    var dmg: float = weaponData.damage * (2.0 if boss else 1.0)
                    _cm.aiState.send_ai_damage_to_peer(peerId, dmg, weaponData.penetration)

        elif hitCollider.is_in_group(&"Player"):
            var dmg: float = weaponData.damage * (2.0 if boss else 1.0)
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
    if !is_instance_valid(_cm) || !_cm.is_session_active():
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
            _cm.aiState.broadcast_ai_fire(syncId)

        if playerDistance3D > 50:
            await get_tree().create_timer(0.1, false).timeout
            if !is_instance_valid(self):
                return
            PlayCrack()

## Host applies damage locally; client routes to host via RPC.
func WeaponDamage(hitbox: String, damage: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.WeaponDamage(hitbox, damage)
        return
    if _cm.isHost:
        super.WeaponDamage(hitbox, damage)
        return
    if !has_meta(&"ai_sync_id"):
        return
    var syncId: int = get_meta(&"ai_sync_id")
    _cm.aiState.request_ai_damage_from_client.rpc_id(1, syncId, hitbox, damage)

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


func _broadcast_voice(voiceType: int) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active() || !_cm.isHost:
        return
    if !has_meta(&"ai_sync_id"):
        return
    _cm.aiState.broadcast_ai_voice(get_meta(&"ai_sync_id"), voiceType)


func Death(direction: Vector3, force: float) -> void:
    if is_instance_valid(_cm) && _cm.is_session_active() && _cm.isHost:
        if has_meta(&"ai_sync_id"):
            var syncId: int = get_meta(&"ai_sync_id")
            _cm.aiState.broadcast_ai_death(syncId, direction, force)
    super.Death(direction, force)


## Broadcasts AI-triggered door opens; AI only runs on host so this is the sync point.
func Interactor(delta: float) -> void:
    # Snapshot before super so fresh-open detection has something to compare.
    var doorBefore: Node = null
    if is_instance_valid(forward) && forward.is_colliding():
        var hit: Node = forward.get_collider()
        if is_instance_valid(hit) && hit.is_in_group(&"Interactable") && hit.owner is Door:
            if !hit.owner.isOpen && !hit.owner.locked && !hit.owner.jammed:
                doorBefore = hit.owner

    super.Interactor(delta)

    if !is_instance_valid(doorBefore):
        return
    if !is_instance_valid(_cm) || !_cm.is_session_active() || !_cm.isHost:
        return
    if doorBefore.isOpen:
        var doorPath: String = get_tree().current_scene.get_path_to(doorBefore)
        _cm.worldState.sync_door_state.rpc(doorPath, true)
        if _cm.DEBUG:
            print("[ai_patch] AI opened door %s — broadcast" % doorPath)

