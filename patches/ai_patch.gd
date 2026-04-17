## Patch for [code]AI.gd[/code] — multi-player detection and network hooks.
##
## Overrides:
## [br]- [method _physics_process]: skip all AI logic on clients (driven by ai_state.gd)
## [br]- [method Parameters]: scan all players (host + remotes), target nearest
## [br]- [method Sensor]: LOS check against targeted player's position
## [br]- [method LOSCheck]: recognize remote player colliders ("CoopRemote" group)
## [br]- [method Hearing]: detect any player's movement, not just gameData
## [br]- [method FireDetection]: check firing state from any player
## [br]- [method Raycast]: handle hits on remote players via damage RPC
## [br]- [method Fire]: broadcast fire event to clients
## [br]- [method Death]: broadcast death event to clients
##
## On clients, the AI scene exists but is fully driven by [code]ai_state.gd[/code] snapshots.
## Original behaviour is 100% preserved when not in a co-op session.
extends "res://Scripts/AI.gd"

var _cm: Node

## Which player this AI is currently targeting. -1 = host's local player.
var targetPeerId: int = -1


## Collision layer 20 (bit 19) — matches remote_player.gd COOP_HIT_LAYER.
const COOP_HIT_LAYER: int = 1 << 19


func init_manager(manager: Node) -> void:
    _cm = manager
    # Add co-op hit layer to AI raycasts so they detect remote player HitBodies
    if fire != null:
        fire.collision_mask |= COOP_HIT_LAYER
    if LOS != null:
        LOS.collision_mask |= COOP_HIT_LAYER


## Override _ready to preserve base game's deferred Initialize call.
func _ready() -> void:
    super._ready()


## Override Initialize to find map/AISpawner by walking up from self instead of
## using absolute /root/Map path. The original absolute path breaks when Village
## or other maps are instantiated inside a headless SubViewport (for cross-map
## AI simulation). When the node isn't inside a SubViewport, walking up still
## finds the scene root correctly so solo behaviour is preserved.
func Initialize():
    await get_tree().physics_frame

    navigationMap = get_world_3d().get_navigation_map()
    # Find the map node by walking up the ancestor chain — works both for
    # the real scene (map at /root/Map) and for headless SubViewports.
    var mapAncestor: Node = _find_map_ancestor()
    if mapAncestor != null:
        map = mapAncestor
        var aiNode: Node = mapAncestor.get_node_or_null("AI")
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

    voiceCycle = randf_range(10.0, 60.0)
    sensorActive = true


## Walks up from self to find the map node. Identifies it by having an "AI" child
## (which every gameplay map has) or by being the scene root below a SubViewport.
## More robust than matching by name since .scn scene roots may vary.
func _find_map_ancestor() -> Node:
    var node: Node = self
    while node != null:
        if node.get_node_or_null("AI") != null:
            return node
        var parent: Node = node.get_parent()
        # If parent is a SubViewport, this node is the scene root of the headless map.
        if parent is SubViewport:
            return node
        node = parent
    return null

# ---------- Physics Process ----------


func _physics_process(delta: float) -> void:
    if _cm == null:
        var root: Node = get_tree().root if get_tree() != null else null
        if root != null:
            for child: Node in root.get_children():
                if child.has_meta(&"is_coop_manager"):
                    _cm = child
                    break
    if is_instance_valid(_cm) && _cm.is_session_active():
        if !_cm.isHost:
            # Client: AI visuals driven entirely by ai_state.gd snapshots
            return
        # Host: remove the gameData.isDead guard so AI stays active
        # when the host player dies but other players are still alive
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


## Returns true only if ALL players are dead (host + remotes).
func _all_players_dead() -> bool:
    if !gameData.isDead:
        return false
    for peerId: int in _cm.remoteNodes:
        var remote: Node3D = _cm.remoteNodes[peerId]
        if is_instance_valid(remote) && !remote.get_meta(&"is_dead", false):
            return false
    return true

# ---------- Parameters (Nearest Player Targeting) ----------


func Parameters(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Parameters(delta)
        return

    LKL = lerp(LKL, lastKnownLocation, delta * LKLSpeed)

    # Find nearest player across host + all remotes
    var bestPos: Vector3 = gameData.playerPosition
    var bestDist: float = global_position.distance_to(bestPos)
    var bestVector: Vector3 = gameData.playerVector
    targetPeerId = -1

    for peerId: int in _cm.remoteNodes:
        var remote: Node3D = _cm.remoteNodes[peerId]
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        var pos: Vector3 = remote.global_position
        var dist: float = global_position.distance_to(pos)
        if dist < bestDist:
            bestDist = dist
            bestPos = pos
            targetPeerId = peerId
            var rotY: float = remote.targetRotationY
            bestVector = Vector3(-sin(rotY), 0, -cos(rotY))

    playerPosition = bestPos
    playerDistance3D = bestDist
    playerDistance2D = Vector2(global_position.x, global_position.z).distance_to(
        Vector2(bestPos.x, bestPos.z))
    # Use the targeted player's facing vector for fire detection
    fireVector = (global_position - bestPos).normalized().dot(bestVector)

    # Adaptive sensor cycle (same thresholds as original)
    if playerDistance3D < 10 && playerVisible:
        sensorCycle = 0.05
        LKLSpeed = 4.0
    elif playerDistance3D > 10 && playerDistance3D < 50:
        sensorCycle = 0.1
        LKLSpeed = 2.0
    elif playerDistance3D > 50:
        sensorCycle = 0.5
        LKLSpeed = 1.0

# ---------- Sensor ----------


func Sensor(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Sensor(delta)
        return

    sensorTimer += delta
    if sensorTimer > sensorCycle:
        if playerDistance3D <= 200.0:
            # Use targeted player's camera/eye position for LOS
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


## Returns the camera/eye position of the currently targeted player.
## Host local player uses [code]gameData.cameraPosition[/code].
## Remote players approximate eye height at +1.6m.
func _get_target_camera_position() -> Vector3:
    if targetPeerId < 0:
        return gameData.cameraPosition
    var remote: Node3D = _cm.remoteNodes.get(targetPeerId)
    if !is_instance_valid(remote):
        return gameData.cameraPosition
    return remote.global_position + Vector3(0, 1.6, 0)

# ---------- LOSCheck ----------


func LOSCheck(target: Vector3) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.LOSCheck(target)
        return

    # Set LOS range based on conditions (same logic as original)
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
        # Original: check "Player" group (host's local player)
        # Co-op: also check "CoopRemote" group (remote players)
        if collider.is_in_group(&"Player") || collider.is_in_group(&"CoopRemote"):
            lastKnownLocation = playerPosition
            playerVisible = true

            if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
                Decision()
            elif currentState == State.Ambush:
                ChangeState("Combat")
            return

    playerVisible = false

# ---------- Hearing ----------


func Hearing() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Hearing()
        return

    # Check host's local player (original logic)
    if (playerDistance3D < 20 && gameData.isRunning) || (playerDistance3D < 5 && gameData.isWalking):
        if currentState != State.Ambush:
            lastKnownLocation = playerPosition
        if currentState == State.Wander || currentState == State.Guard || currentState == State.Patrol:
            Decision()
        return

    for peerId: int in _cm.remoteNodes:
        var remote: Node3D = _cm.remoteNodes[peerId]
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

# ---------- FireDetection ----------


func FireDetection(delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.FireDetection(delta)
        return

    # Host's local player firing
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

    for peerId: int in _cm.remoteNodes:
        var remote: Node3D = _cm.remoteNodes[peerId]
        if !is_instance_valid(remote) || remote.get_meta(&"is_dead", false):
            continue
        var isFiring: bool = remote.get(&"isFiring") == true if remote.get(&"isFiring") != null else false
        if !isFiring:
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

    # Fire detection timer (same as original)
    if fireDetected:
        fireDetectionTimer += delta
        if fireDetectionTimer > fireDetectionTime:
            extraVisibility = 0.0
            fireDetectionTimer = 0.0
            fireDetected = false

# ---------- Raycast (Hit Remote Players) ----------


func Raycast() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Raycast()
        return

    fire.look_at(FireAccuracy(), Vector3.UP, true)
    fire.force_raycast_update()

    if fire.is_colliding():
        var hitCollider: Node = fire.get_collider()

        if hitCollider.is_in_group(&"CoopRemote"):
            # Hit a remote player — find their peer ID and send damage RPC
            var remoteRoot: Node3D = _cm.find_remote_root(hitCollider)
            if remoteRoot != null:
                var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
                if peerId > 0:
                    var dmg: float = weaponData.damage * (2.0 if boss else 1.0)
                    _cm.aiState.send_ai_damage_to_peer(peerId, dmg, weaponData.penetration)

        elif hitCollider.is_in_group(&"Player"):
            # Hit host's local player (original behavior)
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

# ---------- Fire (Broadcast Event) ----------


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

        # CO-OP: broadcast fire event to clients
        if has_meta(&"ai_sync_id"):
            var syncId: int = get_meta(&"ai_sync_id")
            _cm.aiState.broadcast_ai_fire(syncId)

        if playerDistance3D > 50:
            await get_tree().create_timer(0.1, false).timeout
            if !is_instance_valid(self):
                return
            PlayCrack()

# ---------- WeaponDamage (Client → Host Routing) ----------


## On host: applies damage normally and broadcasts death if killed.
## On client: routes damage to host via RPC instead of applying locally.
func WeaponDamage(hitbox: String, damage: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.WeaponDamage(hitbox, damage)
        return
    if _cm.isHost:
        # Host applies damage locally (original behavior)
        super.WeaponDamage(hitbox, damage)
        return
    # Client: send damage request to host
    if !has_meta(&"ai_sync_id"):
        return
    var syncId: int = get_meta(&"ai_sync_id")
    _cm.aiState.request_ai_damage_from_client.rpc_id(1, syncId, hitbox, damage)

# ---------- Audio Broadcasts ----------


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


# ---------- Death (Broadcast Event) ----------


func Death(direction: Vector3, force: float) -> void:
    if is_instance_valid(_cm) && _cm.is_session_active() && _cm.isHost:
        if has_meta(&"ai_sync_id"):
            var syncId: int = get_meta(&"ai_sync_id")
            _cm.aiState.broadcast_ai_death(syncId, direction, force)
    super.Death(direction, force)

# ---------- Helpers ----------


