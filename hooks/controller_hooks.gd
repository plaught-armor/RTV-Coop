## Hook callbacks for Controller.gd — net broadcast hooks + flattened input/footstep.
## Replaces patches/controller_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Per-instance state (audioPool, wasFiring) lives in dicts keyed by Controller node.
extends RefCounted


const AUDIO_POOL_INITIAL: int = 8
const PATH_RIG_MANAGER: NodePath = ^"../Camera/Manager"

var _lib: Object = null
var _audioPool: Dictionary[Controller, Array] = {}
var _wasFiring: Dictionary[Controller, bool] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("controller-_ready-post", _on_ready_post)
    lib.hook("controller-_input", _on_input)
    lib.hook("controller-movement-post", _on_movement_post)
    lib.hook("controller-inertia", _on_inertia)
    lib.hook("controller-surfacedetection", _on_surface_detection)
    lib.hook("controller-playfootstep", _on_play_footstep)
    lib.hook("controller-playfootstepjump", _on_play_footstep_jump)
    lib.hook("controller-playfootstepland", _on_play_footstep_land)
    lib.hook("controller-playmovementcloth", _on_play_movement_cloth)
    lib.hook("controller-playmovementgear", _on_play_movement_gear)


func _on_ready_post() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    CoopManager._log("[controller.trace] _ready_post ENTER")
    _warm_audio_pool(c)
    CoopManager._log("[controller.trace] _ready_post audio pool warmed")


func _warm_audio_pool(c: Controller) -> void:
    var pool: Array[AudioStreamPlayer] = []
    for i: int in AUDIO_POOL_INITIAL:
        var player: AudioStreamPlayer = c.audioInstance2D.instantiate()
        player.set_script(null)
        player.set_process(false)
        c.add_child(player)
        pool.append(player)
    _audioPool[c] = pool


func _get_audio_player(c: Controller) -> AudioStreamPlayer:
    var pool: Array = _audioPool.get(c, [])
    for player: AudioStreamPlayer in pool:
        if !player.playing:
            return player
    var player: AudioStreamPlayer = c.audioInstance2D.instantiate()
    player.set_script(null)
    player.set_process(false)
    c.add_child(player)
    pool.append(player)
    _audioPool[c] = pool
    return player


func _play_pooled(c: Controller, audioEvent: AudioEvent) -> void:
    if audioEvent.audioClips.is_empty():
        return
    var player: AudioStreamPlayer = _get_audio_player(c)
    player.stream = audioEvent.audioClips.pick_random()
    if audioEvent.randomPitch:
        player.volume_db = randf_range(audioEvent.volume - 1.0, audioEvent.volume)
        player.pitch_scale = randf_range(0.9, 1.0)
    else:
        player.volume_db = audioEvent.volume
        player.pitch_scale = 1.0
    player.play()


func _on_input(event: InputEvent) -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    if CoopManager.gd.freeze || CoopManager.gd.isCaching || CoopManager.gd.vehicle:
        return
    if !(event is InputEventMouseMotion):
        return
    var sens: float
    if CoopManager.gd.isAiming && CoopManager.gd.isScoped:
        sens = CoopManager.gd.scopeSensitivity
    elif CoopManager.gd.isAiming:
        sens = CoopManager.gd.aimSensitivity
    else:
        sens = CoopManager.gd.lookSensitivity
    var factor: float = clampf(sens, 0.1, 2.0) / 10.0
    var ySign: float = 1.0 if CoopManager.gd.mouseMode == 2 else -1.0
    c.rotate_y(deg_to_rad(-event.relative.x * factor))
    c.head.rotate_x(deg_to_rad(ySign * event.relative.y * factor))
    c.head.rotation.x = clamp(c.head.rotation.x, deg_to_rad(-90), deg_to_rad(90))


func _on_movement_post(_delta: float) -> void:
    if !CoopManager.is_session_active():
        return
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    CoopManager.playerState.broadcast_position(
        c.global_transform.origin,
        Vector3(c.rotation.y, c.head.rotation.x, 0.0),
        CoopManager.playerState.encode_flags(CoopManager.gd),
    )
    CoopManager.playerState.broadcast_vitals()
    var firing: bool = CoopManager.gd.isFiring
    var prevFiring: bool = _wasFiring.get(c, false)
    if firing && !prevFiring:
        _broadcast_fire_event(c)
    _wasFiring[c] = firing


func _on_inertia(delta: float) -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    if CoopManager.gd.isWalking || CoopManager.gd.isRunning:
        var backwardPenalty: float = 0.7 if CoopManager.gd.isRunning else 0.8
        if c.inputDirection.y > 0.5:
            c.inertia = lerpf(c.inertia, 0.6, delta * 2.0)
        elif c.inputDirection.y >= 0:
            c.inertia = lerpf(c.inertia, backwardPenalty, delta * 2.0)
        else:
            c.inertia = lerpf(c.inertia, 1.0, delta * 2.0)
    else:
        c.inertia = lerpf(c.inertia, 1.0, delta * 2.0)


func _on_surface_detection(delta: float) -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    c.scanTimer += delta
    if c.scanTimer <= c.scanCycle:
        return
    c.scanTimer = 0.0
    if c.below.is_colliding():
        CoopManager.gd.surface = "Generic"
        var collider: Object = c.below.get_collider()
        if collider is Surface:
            CoopManager.gd.surface = collider.surface
    CoopManager.gd.leanLBlocked = c.left.is_colliding()
    CoopManager.gd.leanRBlocked = c.right.is_colliding()


## Surface→AudioEvent mapping. Vanilla Controller has no ResolveFootstep helper —
## this is a mod-side reimpl of the same surface-tag dispatch the vanilla Play*
## methods do inline. Keep return contract Variant-compatible with vanilla audio fields.
func _resolve_footstep(c: Controller, isLanding: bool) -> AudioEvent:
    var lib: AudioLibrary = c.audioLibrary
    if lib == null:
        CoopManager._log("[controller.trace] _resolve_footstep audioLibrary NULL")
        return null
    var surf: String = CoopManager.gd.surface as String
    if surf.is_empty():
        return lib.footstepGenericLand if isLanding else lib.footstepGeneric
    match surf[0]:
        "G":
            # Grass vs Generic — second char disambiguates.
            if surf.length() > 1 && surf[1] == "r":
                if CoopManager.gd.season == 2:
                    return lib.footstepSnowHardLand if isLanding else lib.footstepSnowHard
                return lib.footstepGrassLand if isLanding else lib.footstepGrass
            return lib.footstepGenericLand if isLanding else lib.footstepGeneric
        "D":
            if CoopManager.gd.season == 2:
                return lib.footstepSnowHardLand if isLanding else lib.footstepSnowHard
            return lib.footstepDirtLand if isLanding else lib.footstepDirt
        "A":
            return lib.footstepAsphaltLand if isLanding else lib.footstepAsphalt
        "R":
            return lib.footstepRockLand if isLanding else lib.footstepRock
        "W":
            return lib.footstepWoodLand if isLanding else lib.footstepWood
        "M":
            return lib.footstepMetalLand if isLanding else lib.footstepMetal
        "C":
            return lib.footstepConcreteLand if isLanding else lib.footstepConcrete
        _:
            return lib.footstepGenericLand if isLanding else lib.footstepGeneric


func _play_footstep_and_broadcast(c: Controller, isLanding: bool) -> void:
    var audio: AudioEvent
    if CoopManager.gd.isWater:
        audio = c.audioLibrary.footstepWaterLand if isLanding else c.audioLibrary.footstepWater
    else:
        audio = _resolve_footstep(c, isLanding)
    if audio == null:
        CoopManager._log("[controller.trace] footstep audio NULL surface=%s isWater=%s isLanding=%s" % [str(CoopManager.gd.surface), str(CoopManager.gd.isWater), str(isLanding)])
        return
    _play_pooled(c, audio)
    if CoopManager.is_session_active():
        CoopManager.playerState.broadcast_footstep(audio.resource_path)


func _on_play_footstep() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    if c.character.heavyGear && randi_range(1, 2) == 1:
        c.PlayMovementGear()
    _play_footstep_and_broadcast(c, false)


func _on_play_footstep_jump() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    c.PlayMovementCloth()
    if c.character.heavyGear:
        c.PlayMovementGear()
    _play_footstep_and_broadcast(c, false)


func _on_play_footstep_land() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    c.PlayMovementCloth()
    if c.character.heavyGear:
        c.PlayMovementGear()
    _play_footstep_and_broadcast(c, true)


func _on_play_movement_cloth() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    _play_pooled(c, c.audioLibrary.movementCloth)


func _on_play_movement_gear() -> void:
    var c: Controller = _lib._caller as Controller
    if c == null:
        return
    _lib.skip_super()
    _play_pooled(c, c.audioLibrary.movementGear)


func _broadcast_fire_event(c: Controller) -> void:
    var rm: Node3D = c.get_node_or_null(PATH_RIG_MANAGER)
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
    var hit: Dictionary = _trace_bullet_impact(c)
    CoopManager.playerState.broadcast_fire_event(fireAudio, tailAudio, !hasSuppressor, hit.point, hit.normal, hit.surface)


func _resolve_fire_audio(weaponData: Resource, hasSuppressor: bool) -> Dictionary:
    var fireAudio: String = ""
    var tailAudio: String = ""
    var fireRes: Resource = null
    var tailRes: Resource = null
    var indoorVal: Variant = CoopManager.gd.get(&"indoor")
    var indoor: bool = indoorVal == true
    if hasSuppressor:
        fireRes = weaponData.get(&"fireSuppressed")
        tailRes = weaponData.get(&"tailIndoorSuppressed") if indoor else weaponData.get(&"tailOutdoorSuppressed")
    else:
        var modeVal: Variant = CoopManager.gd.get(&"firemode")
        var mode: int = int(modeVal) if modeVal != null else 1
        fireRes = weaponData.get(&"fireAuto") if mode == 2 else weaponData.get(&"fireSemi")
        tailRes = weaponData.get(&"tailIndoor") if indoor else weaponData.get(&"tailOutdoor")
    if fireRes != null:
        fireAudio = fireRes.resource_path
    if tailRes != null:
        tailAudio = tailRes.resource_path
    return {"fire": fireAudio, "tail": tailAudio}


func _trace_bullet_impact(c: Controller) -> Dictionary:
    var out: Dictionary = {"point": Vector3.ZERO, "normal": Vector3.ZERO, "surface": ""}
    var cam: Camera3D = c.get_viewport().get_camera_3d()
    if cam == null:
        return out
    var space: PhysicsDirectSpaceState3D = c.get_world_3d().direct_space_state
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
