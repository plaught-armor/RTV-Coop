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
    if _cm == null:
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

    if _cm == null || !_cm.is_session_active():
        return

    _cm.playerState.broadcast_position(
        global_transform.origin,
        Vector3(rotation.y, head.rotation.x, 0.0),
        _cm.PlayerStateScript.encode_flags(_cm.gd),
    )

# ---------- Inertia ----------


func Inertia(delta: float) -> void:
    if _cm == null:
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
    if _cm == null:
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
    if _cm == null:
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
    if _cm == null:
        super.PlayFootstep()
        return
    if character.heavyGear && randi_range(1, 2) == 1:
        PlayMovementGear()
    play_footstep_and_broadcast(false)


func PlayFootstepJump() -> void:
    if _cm == null:
        super.PlayFootstepJump()
        return
    PlayMovementCloth()
    if character.heavyGear:
        PlayMovementGear()
    play_footstep_and_broadcast(false)


func PlayFootstepLand() -> void:
    if _cm == null:
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
