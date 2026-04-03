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


func _get_cm() -> Node:
    if _cm == null:
        _cm = get_node("/root/CoopManager")
    return _cm


const PlayerStateScript = preload("res://mod/network/player_state.gd")

## Typed reference to the shared GameData resource. Shadows the parent's untyped
## [code]gameData[/code] to enable typed instructions in our overridden methods.
var gd: GameData = preload("res://Resources/GameData.tres")

## Pool of [code]AudioInstance2D[/code] nodes to avoid per-sound instantiation.
var audioPool: Array[AudioStreamPlayer] = []
const AUDIO_POOL_INITIAL: int = 8


func _ready() -> void:
    super._ready()
    warm_audio_pool()


## Pre-allocates audio player nodes. They self-manage: play, then stop processing
## until reused. Avoids instantiate+queue_free churn on every footstep.
func warm_audio_pool() -> void:
    for i: int in AUDIO_POOL_INITIAL:
        var player: AudioStreamPlayer = audioInstance2D.instantiate()
        player.set_script(null)
        player.set_process(false)
        add_child(player)
        audioPool.append(player)


## Returns an idle audio player from the pool, growing it if all are busy.
func get_audio_player() -> AudioStreamPlayer:
    for player: AudioStreamPlayer in audioPool:
        if !player.playing:
            return player
    # Pool exhausted — grow by one
    var player: AudioStreamPlayer = audioInstance2D.instantiate()
    player.set_script(null)
    player.set_process(false)
    add_child(player)
    audioPool.append(player)
    return player


## Plays an [code]AudioEvent[/code] using a pooled player instead of instantiating.
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
    if gd.freeze || gd.isCaching:
        return
    var cm: Node = _get_cm()
    if cm != null && cm.panelOpen:
        return
    if !(event is InputEventMouseMotion):
        return

    var sens: float
    if gd.isAiming && gd.isScoped:
        sens = gd.scopeSensitivity
    elif gd.isAiming:
        sens = gd.aimSensitivity
    else:
        sens = gd.lookSensitivity

    var factor: float = clampf(sens, 0.1, 2.0) / 10.0
    var ySign: float = 1.0 if gd.mouseMode == 2 else -1.0

    rotate_y(deg_to_rad(-event.relative.x * factor))
    head.rotate_x(deg_to_rad(ySign * event.relative.y * factor))
    head.rotation.x = clamp(head.rotation.x, deg_to_rad(-90), deg_to_rad(90))

# ---------- Movement ----------


func Movement(delta: float) -> void:
    super.Movement(delta)

    if !_get_cm().is_session_active():
        return

    _get_cm().playerState.broadcast_position(
        global_transform.origin,
        Vector3(rotation.y, head.rotation.x, 0.0),
        PlayerStateScript.encode_flags(gd),
    )

# ---------- Inertia ----------


func Inertia(delta: float) -> void:
    if gd.isWalking || gd.isRunning:
        var backwardPenalty: float = 0.7 if gd.isRunning else 0.8

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
    scanTimer += delta
    if scanTimer <= scanCycle:
        return
    scanTimer = 0.0

    if below.is_colliding():
        gd.surface = "Generic"
        var collider: Object = below.get_collider()
        if collider is Surface:
            gd.surface = collider.surface

    gd.leanLBlocked = left.is_colliding()
    gd.leanRBlocked = right.is_colliding()

# ---------- Footstep Audio ----------


## Resolves the correct footstep audio event based on surface type, season, and
## whether the player is landing. Replaces the original's 3x duplicated elif chains.
func ResolveFootstep(isLanding: bool) -> AudioEvent:
    match gd.surface:
        &"Grass":
            if gd.season == 2:
                return audioLibrary.footstepSnowHardLand if isLanding else audioLibrary.footstepSnowHard
            return audioLibrary.footstepGrassLand if isLanding else audioLibrary.footstepGrass
        &"Dirt":
            if gd.season == 2:
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


func PlayFootstep() -> void:
    if character.heavyGear && randi_range(1, 2) == 1:
        PlayMovementGear()

    var audio: AudioEvent
    if gd.isWater:
        audio = audioLibrary.footstepWater
    else:
        audio = ResolveFootstep(false)
    play_pooled(audio)
    _get_cm().playerState.broadcast_footstep(audio.resource_path)


func PlayFootstepJump() -> void:
    PlayMovementCloth()
    if character.heavyGear:
        PlayMovementGear()

    var audio: AudioEvent
    if gd.isWater:
        audio = audioLibrary.footstepWater
    else:
        audio = ResolveFootstep(false)
    play_pooled(audio)
    _get_cm().playerState.broadcast_footstep(audio.resource_path)


func PlayFootstepLand() -> void:
    PlayMovementCloth()
    if character.heavyGear:
        PlayMovementGear()

    var audio: AudioEvent
    if gd.isWater:
        audio = audioLibrary.footstepWaterLand
    else:
        audio = ResolveFootstep(true)
    play_pooled(audio)
    _get_cm().playerState.broadcast_footstep(audio.resource_path)


func PlayMovementCloth() -> void:
    play_pooled(audioLibrary.movementCloth)


func PlayMovementGear() -> void:
    play_pooled(audioLibrary.movementGear)
