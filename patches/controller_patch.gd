## Patch for [code]Controller.gd[/code] — extends the original script via [code]take_over_path[/code].
##
## Overrides:
## [br]- [method Movement]: appends network position broadcast hook
## [br]- [method _input]: collapses 6-branch sensitivity tree to a single code path
## [br]- [method SurfaceDetection]: direct assignment replaces elif chain
## [br]- [method ResolveFootstep]: match on surface replaces 3x duplicated elif chains
## [br]- [method Inertia]: collapses duplicate walking/running branches
##
## Original behaviour is 100% preserved. The networking hook is a no-op when not connected.
extends "res://Scripts/Controller.gd"

var _cm: Node

var audioPool: Array[AudioStreamPlayer] = []
const AUDIO_POOL_INITIAL: int = 8
var wasFiring: bool = false


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    super._ready()
    warm_audio_pool()


func warm_audio_pool() -> void:
    for i: int in AUDIO_POOL_INITIAL:
        var player: AudioStreamPlayer = audioInstance2D.instantiate()
        player.set_script(null)
        player.set_process(false)
        add_child(player)
        audioPool.append(player)


func get_audio_player() -> AudioStreamPlayer:
    for player: AudioStreamPlayer in audioPool:
        if !player.playing:
            return player
    var player: AudioStreamPlayer = audioInstance2D.instantiate()
    player.set_script(null)
    player.set_process(false)
    add_child(player)
    audioPool.append(player)
    return player


func play_pooled(audioEvent: AudioEvent) -> void:
    if audioEvent.audioClips.is_empty():
        return
    var player: AudioStreamPlayer = get_audio_player()
    player.stream = audioEvent.audioClips.pick_random()
    if audioEvent.randomPitch:
        player.volume_db = randf_range(audioEvent.volume - 1.0, audioEvent.volume)
        player.pitch_scale = randf_range(0.9, 1.0)
    else:
        player.volume_db = audioEvent.volume
        player.pitch_scale = 1.0
    player.play()

# ---------- Input ----------


func _input(event: InputEvent) -> void:
    if !is_instance_valid(_cm):
        return
    if _cm.gd.freeze || _cm.gd.isCaching || _cm.gd.vehicle:
        return
    if _cm.panelOpen:
        return
    if !(event is InputEventMouseMotion):
        return

    var sens: float
    if _cm.gd.isAiming && _cm.gd.isScoped:
        sens = _cm.gd.scopeSensitivity
    elif _cm.gd.isAiming:
        sens = _cm.gd.aimSensitivity
    else:
        sens = _cm.gd.lookSensitivity

    var factor: float = clampf(sens, 0.1, 2.0) / 10.0
    var ySign: float = 1.0 if _cm.gd.mouseMode == 2 else -1.0

    rotate_y(deg_to_rad(-event.relative.x * factor))
    head.rotate_x(deg_to_rad(ySign * event.relative.y * factor))
    head.rotation.x = clamp(head.rotation.x, deg_to_rad(-90), deg_to_rad(90))

# ---------- Movement ----------


func Movement(delta: float) -> void:
    super.Movement(delta)

    if !is_instance_valid(_cm) || !_cm.is_session_active():
        return

    _cm.playerState.broadcast_position(
        global_transform.origin,
        Vector3(rotation.y, head.rotation.x, 0.0),
        _cm.PlayerStateScript.encode_flags(_cm.gd),
    )

    _cm.playerState.broadcast_vitals()

    # Detect fire event rising edge and broadcast to peers
    if _cm.gd.isFiring && !wasFiring:
        _broadcast_fire_event()
    wasFiring = _cm.gd.isFiring

# ---------- Inertia ----------


func Inertia(delta: float) -> void:
    if !is_instance_valid(_cm):
        super.Inertia(delta)
        return
    if _cm.gd.isWalking || _cm.gd.isRunning:
        var backwardPenalty: float = 0.7 if _cm.gd.isRunning else 0.8

        if inputDirection.y > 0.5:
            inertia = lerpf(inertia, 0.6, delta * 2.0)
        elif inputDirection.y >= 0:
            inertia = lerpf(inertia, backwardPenalty, delta * 2.0)
        else:
            inertia = lerpf(inertia, 1.0, delta * 2.0)
    else:
        inertia = lerpf(inertia, 1.0, delta * 2.0)

# ---------- Surface Detection ----------


func SurfaceDetection(delta: float) -> void:
    if !is_instance_valid(_cm):
        super.SurfaceDetection(delta)
        return
    scanTimer += delta
    if scanTimer <= scanCycle:
        return
    scanTimer = 0.0

    if below.is_colliding():
        _cm.gd.surface = "Generic"
        var collider: Object = below.get_collider()
        if collider is Surface:
            _cm.gd.surface = collider.surface

    _cm.gd.leanLBlocked = left.is_colliding()
    _cm.gd.leanRBlocked = right.is_colliding()

# ---------- Footstep Audio ----------


func ResolveFootstep(isLanding: bool) -> AudioEvent:
    if !is_instance_valid(_cm):
        return audioLibrary.footstepGenericLand if isLanding else audioLibrary.footstepGeneric
    match _cm.gd.surface:
        &"Grass":
            if _cm.gd.season == 2:
                return audioLibrary.footstepSnowHardLand if isLanding else audioLibrary.footstepSnowHard
            return audioLibrary.footstepGrassLand if isLanding else audioLibrary.footstepGrass
        &"Dirt":
            if _cm.gd.season == 2:
                return audioLibrary.footstepSnowHardLand if isLanding else audioLibrary.footstepSnowHard
            return audioLibrary.footstepDirtLand if isLanding else audioLibrary.footstepDirt
        &"Asphalt":
            return audioLibrary.footstepAsphaltLand if isLanding else audioLibrary.footstepAsphalt
        &"Rock":
            return audioLibrary.footstepRockLand if isLanding else audioLibrary.footstepRock
        &"Wood":
            return audioLibrary.footstepWoodLand if isLanding else audioLibrary.footstepWood
        &"Metal":
            return audioLibrary.footstepMetalLand if isLanding else audioLibrary.footstepMetal
        &"Concrete":
            return audioLibrary.footstepConcreteLand if isLanding else audioLibrary.footstepConcrete
        _:
            return audioLibrary.footstepGenericLand if isLanding else audioLibrary.footstepGeneric


func play_footstep_and_broadcast(isLanding: bool) -> void:
    var audio: AudioEvent
    if _cm.gd.isWater:
        audio = audioLibrary.footstepWaterLand if isLanding else audioLibrary.footstepWater
    else:
        audio = ResolveFootstep(isLanding)
    play_pooled(audio)
    if _cm.is_session_active():
        _cm.playerState.broadcast_footstep(audio.resource_path)


func PlayFootstep() -> void:
    if !is_instance_valid(_cm):
        super.PlayFootstep()
        return
    if character.heavyGear && randi_range(1, 2) == 1:
        PlayMovementGear()
    play_footstep_and_broadcast(false)


func PlayFootstepJump() -> void:
    if !is_instance_valid(_cm):
        super.PlayFootstepJump()
        return
    PlayMovementCloth()
    if character.heavyGear:
        PlayMovementGear()
    play_footstep_and_broadcast(false)


func PlayFootstepLand() -> void:
    if !is_instance_valid(_cm):
        super.PlayFootstepLand()
        return
    PlayMovementCloth()
    if character.heavyGear:
        PlayMovementGear()
    play_footstep_and_broadcast(true)


func PlayMovementCloth() -> void:
    play_pooled(audioLibrary.movementCloth)


func PlayMovementGear() -> void:
    play_pooled(audioLibrary.movementGear)

# ---------- Fire Event Broadcast ----------


## Detects the active weapon's fire audio and broadcasts to peers.
## Called on the rising edge of [code]gameData.isFiring[/code].
const PATH_RIG_MANAGER: NodePath = ^"../Camera/Manager"


func _broadcast_fire_event() -> void:
    var rm: Node3D = get_node_or_null(PATH_RIG_MANAGER)
    if rm == null || rm.get_child_count() == 0:
        return
    var rig: Node = rm.get_child(rm.get_child_count() - 1)
    var weaponData: Resource = rig.get(&"data")
    if weaponData == null:
        return

    var hasSuppressor: bool = rig.get(&"activeMuzzle") != null || (weaponData.get(&"nativeSuppressor") == true)
    var audio: Dictionary = _resolve_fire_audio(weaponData, hasSuppressor)
    var fireAudio: String = audio.fire
    var tailAudio: String = audio.tail

    if fireAudio.is_empty():
        return

    var hit: Dictionary = _trace_bullet_impact()
    _cm.playerState.broadcast_fire_event(fireAudio, tailAudio, !hasSuppressor, hit.point, hit.normal, hit.surface)


## Returns {fire, tail} audio resource paths for the current weapon mode,
## taking suppressor state and indoor/outdoor context into account.
func _resolve_fire_audio(weaponData: Resource, hasSuppressor: bool) -> Dictionary:
    var fireAudio: String = ""
    var tailAudio: String = ""
    var fireRes: Resource = null
    var tailRes: Resource = null
    var indoor: bool = _cm.gd.get(&"indoor", false)

    if hasSuppressor:
        fireRes = weaponData.get(&"fireSuppressed")
        tailRes = weaponData.get(&"tailIndoorSuppressed") if indoor else weaponData.get(&"tailOutdoorSuppressed")
    else:
        var mode: int = _cm.gd.get(&"firemode", 1)
        fireRes = weaponData.get(&"fireAuto") if mode == 2 else weaponData.get(&"fireSemi")
        tailRes = weaponData.get(&"tailIndoor") if indoor else weaponData.get(&"tailOutdoor")

    if fireRes != null:
        fireAudio = fireRes.resource_path
    if tailRes != null:
        tailAudio = tailRes.resource_path

    return {"fire": fireAudio, "tail": tailAudio}


## Casts a ray from the camera 200m forward and returns impact {point, normal, surface}.
## Returns zero-ed values + empty surface if nothing is hit.
func _trace_bullet_impact() -> Dictionary:
    var out: Dictionary = {"point": Vector3.ZERO, "normal": Vector3.ZERO, "surface": ""}
    var cam: Camera3D = get_viewport().get_camera_3d()
    if cam == null:
        return out
    var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    var from: Vector3 = cam.global_position
    var to: Vector3 = from - cam.global_transform.basis.z * 200.0
    var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
    var result: Dictionary = space.intersect_ray(query)
    if result.is_empty():
        return out
    out.point = result["position"]
    out.normal = result["normal"]
    var collider: Object = result["collider"]
    if collider != null && collider.get(&"surface") != null:
        out.surface = collider.get(&"surface")
    else:
        out.surface = "Generic"
    return out
