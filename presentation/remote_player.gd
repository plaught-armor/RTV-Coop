## Rigged visual for a remote co-op player. Consumes interpolated snapshots
## from [PlayerState] via [method update_state] + equipment/fire RPCs; never
## reads [GameData] directly.
extends Node3D


## Fallback grip transforms for weapons the AI scenes never placed (HK416,
## MK18, MP7, etc.). Lifted from the RIFLE_B / PISTOL archetypes in the
## Bandit AI scene — matches the "close enough for every weapon of this
## class" slop the competitor mod relies on.
const FALLBACK_RIFLE_GRIP: Transform3D = Transform3D(
    Vector3(-0.168531, 0.983905, 0.0593909),
    Vector3(0.17101, -0.0301536, 0.984808),
    Vector3(0.97075, 0.176127, -0.163175),
    Vector3(0.103742, 0.101099, 0.0396876)
)
const FALLBACK_PISTOL_GRIP: Transform3D = Transform3D(
    Vector3(0.174912, 0.982636, -0.0618917),
    Vector3(0.0847189, 0.047607, 0.995267),
    Vector3(0.980934, -0.179328, -0.07492),
    Vector3(0.0715436, 0.101432, 0.0108366)
)


var _cm: Node


var targetPosition: Vector3 = Vector3.ZERO
var targetRotationY: float = 0.0
var targetRotationX: float = 0.0
var moveFlags: int = 0
var displayName: String = "":
    set(value):
        displayName = value
        _lastRenderedHealth = -999
var isDead: bool = false
var _lastRenderedHealth: int = -999
## Cached so _physics_process doesn't re-resolve _cm.PlayerStateScript.MoveFlag.
var _moveFlag: Dictionary = {}
## [method set_appearance] fires twice on spawn (default + RPC) and peers may
## re-broadcast later; cache avoids redundant .tres parses.
var _materialCache: Dictionary[String, Material] = {}

var audioPlayer: AudioStreamPlayer3D = null

var occlusionRay: PhysicsRayQueryParameters3D = null
var isOccluded: bool = false
const OCCLUSION_CHECK_TICKS: int = 24
const OCCLUSION_DB_PENALTY: float = -8.0
const OCCLUSION_CUTOFF_HZ: float = 800.0
static var occludedBusName: StringName = &""
static var occludedBusIdx: int = -1

var modelRoot: Node3D = null
var animTree: AnimationTree = null
var skeleton: Skeleton3D = null
## Spine bone index for aim-pitch override. Resolved once at rig load.
var _spineBone: int = -1
## Smoothed pitch (radians); avoids jitter when incoming snapshots land between
## physics ticks.
var _spinePitch: float = 0.0
## Spotlight parented to the Head bone so remote players cast useful light
## matching their aim direction. Created lazily the first time the peer turns
## a flashlight on. [member _flashlightOn] tracks the remote's current state.
var _flashlightMount: BoneAttachment3D = null
var _flashlight: SpotLight3D = null
var _flashlightOn: bool = false
const SPINE_BONE_NAME: StringName = &"Spine_03"
const HEAD_BONE_NAME: StringName = &"Head"
const SPINE_PITCH_WEIGHT: float = 0.7
## [MeshInstance3D] children of Skeleton3D keyed by body name.
## After [method set_appearance] the losers are freed, leaving one entry.
var bodyMeshes: Dictionary[String, MeshInstance3D] = {}
var flashNode: Node3D = null
var activeWeapon: Node3D = null
var activeMuzzle: Node3D = null

var currentSpeed: float = 0.0
var targetSpeed: float = 0.0
const SPEED_IDLE: float = 0.0
const SPEED_WALK: float = 1.0
const SPEED_RUN: float = 2.0
const SPEED_SPRINT: float = 3.0
## Cached as StringNames — writing to AnimationTree via a raw String allocates
## every physics frame.
const ANIM_PARAM_MOVEMENT_BLEND: StringName = &"parameters/Rifle/Movement/blend_position"
const ANIM_PARAM_COND_RIFLE: StringName = &"parameters/conditions/Rifle"
const ANIM_PARAM_COND_PISTOL: StringName = &"parameters/conditions/Pistol"
const ANIM_PARAM_COND_MOVEMENT: StringName = &"parameters/Rifle/conditions/Movement"

## Bit 19 — ai_patch.gd adds only this bit to its fire/LOS masks, so the
## HitBody is invisible to Interactor, player weapons, and other systems.
const COOP_HIT_LAYER: int = 1 << 19


@onready var nameLabel: Label3D = $NameLabel


func init_manager(manager: Node) -> void:
    _cm = manager
    _moveFlag = _cm.PlayerStateScript.MoveFlag
    nameLabel.text = displayName
    targetPosition = global_position

    audioPlayer = AudioStreamPlayer3D.new()
    audioPlayer.max_distance = 50.0
    audioPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
    add_child(audioPlayer)

    _ensure_occluded_bus()
    _create_collision_body()
    add_to_group("CoopRemote")

    _load_super_rig()

    var defaults: Dictionary = _cm.AppearanceScript.get_defaults()
    set_appearance(defaults.body, defaults.material)


func _load_super_rig() -> void:
    var packed: PackedScene = load(_cm.AppearanceScript.SUPER_RIG_PATH) as PackedScene
    if packed == null:
        push_warning("super rig missing — run tools/build_super_rig.gd in editor")
        return

    # The super rig root is a CharacterBody3D wrapper; we only want its Body
    # child so remote players don't carry a phantom physics body.
    var rigRoot: Node = packed.instantiate()
    if rigRoot == null:
        return
    var body: Node3D = rigRoot.get_node_or_null("Body") as Node3D
    if body == null:
        for child: Node in rigRoot.get_children():
            if child is Node3D:
                body = child
                break
    if body == null:
        rigRoot.queue_free()
        return

    # Collision + Flash sit at the scene root (matching AI_*.tscn); pull them
    # into Body before freeing the wrapper so they follow the rig.
    for siblingName: String in ["Collision", "Flash"]:
        var sibling: Node = rigRoot.get_node_or_null(siblingName)
        if sibling != null:
            rigRoot.remove_child(sibling)
            body.add_child(sibling)

    rigRoot.remove_child(body)
    rigRoot.queue_free()
    modelRoot = body
    add_child(modelRoot)

    animTree = modelRoot.get_node_or_null("Animator") as AnimationTree
    flashNode = modelRoot.get_node_or_null("Flash") as Node3D
    skeleton = modelRoot.get_node_or_null("Armature/Skeleton3D") as Skeleton3D
    if skeleton != null:
        _spineBone = skeleton.find_bone(SPINE_BONE_NAME)
        for child: Node in skeleton.get_children():
            if child is MeshInstance3D && child.name.begins_with("Mesh_"):
                var key: String = child.name.substr(5)
                bodyMeshes[key] = child
                (child as MeshInstance3D).visible = false
    _activate_animator()


## Equipment-sync entry point. Empty [param weaponName] clears the attachment.
func set_active_weapon(weaponName: String) -> void:
    if modelRoot == null:
        return
    var weapons: Node = modelRoot.get_node_or_null("Armature/Skeleton3D/Weapons")
    if weapons == null:
        return

    # Hide the previous baked template or queue_free a previous dynamic
    # instance (dynamic ones live under Weapons with name "_coop_dyn").
    if is_instance_valid(activeWeapon):
        if activeWeapon.name == &"_coop_dyn":
            activeWeapon.queue_free()
        else:
            activeWeapon.visible = false
    activeWeapon = null
    activeMuzzle = null

    if weaponName.is_empty() || !_is_valid_weapon_name(weaponName):
        return
    # The super rig bakes every AI-owned weapon under Weapons as an invisible
    # template (see tools/build_super_rig.gd); we just flip the matching one
    # visible to preserve the authored Hand_R transforms.
    var baked: Node3D = weapons.get_node_or_null(weaponName) as Node3D
    if baked != null:
        baked.visible = true
        activeWeapon = baked
        activeMuzzle = baked.get_node_or_null("Muzzle") as Node3D
        return
    # No baked template — load the weapon fresh and apply a class-wide grip.
    _attach_dynamic_weapon(weapons, weaponName)


## Instantiates a weapon scene on demand for names not pre-baked into the
## super rig. Uses a pistol/rifle fallback transform, mirroring how the
## competitor mod handles every weapon.
func _attach_dynamic_weapon(weapons: Node, weaponName: String) -> void:
    var path: String = "res://Items/Weapons/%s/%s.tscn" % [weaponName, weaponName]
    if !_cm.AppearanceScript.is_visually_allowed(path):
        return
    if !ResourceLoader.exists(path):
        return
    var packed: PackedScene = load(path) as PackedScene
    if packed == null:
        return
    var weapon: Node = packed.instantiate()
    if weapon == null:
        return
    weapon.name = &"_coop_dyn"
    weapon.set_script(null)
    if weapon is RigidBody3D:
        var rb: RigidBody3D = weapon
        rb.freeze = true
        rb.collision_layer = 0
        rb.collision_mask = 0
    var isPistol: bool = false
    if weapon.has_method(&"get") && weapon.get(&"slotData") != null:
        var data: Resource = weapon.slotData.itemData if weapon.slotData != null else null
        if data != null && data.get(&"weaponType") == "Pistol":
            isPistol = true
    if weapon is Node3D:
        (weapon as Node3D).transform = FALLBACK_PISTOL_GRIP if isPistol else FALLBACK_RIFLE_GRIP
    weapons.add_child(weapon)
    activeWeapon = weapon as Node3D
    activeMuzzle = weapon.get_node_or_null("Muzzle") as Node3D


## Allowlist for weapon file names — prevents path traversal / arbitrary load
## through the equipment RPC.
static func _is_valid_weapon_name(name: String) -> bool:
    if name.length() > 32:
        return false
    for i: int in name.length():
        var c: int = name.unicode_at(i)
        var ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
        if !ok:
            return false
    return true


func set_appearance(body: String, materialPath: String) -> void:
    if !_cm.AppearanceScript.is_valid({"body": body, "material": materialPath}):
        return
    if modelRoot == null:
        return

    # Appearance is picked once per world; free the three losers so the remote
    # doesn't carry unused skinned meshes on the GPU.
    var losers: Array[String] = []
    for key: String in bodyMeshes:
        if key != body:
            losers.append(key)
    for key: String in losers:
        var mesh: MeshInstance3D = bodyMeshes[key]
        if is_instance_valid(mesh):
            mesh.queue_free()
        bodyMeshes.erase(key)

    var selected: MeshInstance3D = bodyMeshes.get(body)
    if selected == null:
        return
    selected.visible = true
    var mat: Material = _load_material(materialPath)
    if mat != null:
        for i: int in selected.get_surface_override_material_count():
            selected.set_surface_override_material(i, mat)


func _load_material(path: String) -> Material:
    var cached: Material = _materialCache.get(path)
    if cached != null:
        return cached
    var mat: Material = load(path) as Material
    if mat != null:
        _materialCache[path] = mat
    return mat


func _activate_animator() -> void:
    if animTree == null:
        return
    animTree.active = true
    animTree[ANIM_PARAM_COND_RIFLE] = true
    animTree[ANIM_PARAM_COND_PISTOL] = false
    animTree[ANIM_PARAM_COND_MOVEMENT] = true
    animTree[ANIM_PARAM_MOVEMENT_BLEND] = SPEED_IDLE


func _create_collision_body() -> void:
    var staticBody: StaticBody3D = StaticBody3D.new()
    staticBody.name = "HitBody"
    staticBody.collision_layer = COOP_HIT_LAYER
    staticBody.collision_mask = 0
    staticBody.add_to_group(&"CoopRemote")
    if has_meta(&"peer_id"):
        staticBody.set_meta(&"peer_id", get_meta(&"peer_id"))

    var capsule: CapsuleShape3D = CapsuleShape3D.new()
    capsule.radius = 0.3
    capsule.height = 1.8
    var shape: CollisionShape3D = CollisionShape3D.new()
    shape.shape = capsule
    shape.position.y = 0.9

    staticBody.add_child(shape)
    add_child(staticBody)


## Creates the shared "CoopOccluded" bus lazily — bus indices shift at runtime
## so we look up by name every call and only add the bus on first miss.
static func _ensure_occluded_bus() -> void:
    occludedBusName = &"CoopOccluded"
    var idx: int = AudioServer.get_bus_index(occludedBusName)
    if idx >= 0:
        occludedBusIdx = idx
        return
    AudioServer.add_bus()
    occludedBusIdx = AudioServer.bus_count - 1
    AudioServer.set_bus_name(occludedBusIdx, occludedBusName)
    AudioServer.set_bus_send(occludedBusIdx, &"Master")
    AudioServer.set_bus_volume_db(occludedBusIdx, OCCLUSION_DB_PENALTY)
    var lpf: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
    lpf.cutoff_hz = OCCLUSION_CUTOFF_HZ
    AudioServer.add_bus_effect(occludedBusIdx, lpf)


func _update_occlusion() -> void:
    if !is_instance_valid(audioPlayer) || occludedBusIdx < 0:
        return
    var cam: Camera3D = get_viewport().get_camera_3d()
    if cam == null:
        return

    var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    var from: Vector3 = cam.global_position
    var to: Vector3 = global_position + Vector3(0, 1.0, 0)

    if occlusionRay == null:
        occlusionRay = PhysicsRayQueryParameters3D.create(from, to)
        occlusionRay.collision_mask = 1
        # Exclude the local player so the ray doesn't immediately self-hit.
        var controller: Node = get_tree().current_scene.get_node_or_null("Core/Controller")
        if controller is PhysicsBody3D:
            occlusionRay.exclude = [controller.get_rid()]
    else:
        occlusionRay.from = from
        occlusionRay.to = to

    var result: Dictionary = space.intersect_ray(occlusionRay)
    var nowOccluded: bool = !result.is_empty()

    if nowOccluded != isOccluded:
        isOccluded = nowOccluded
        audioPlayer.bus = occludedBusName if isOccluded else &"Master"


func die() -> void:
    isDead = true
    set_meta(&"is_dead", true)
    set_meta(&"health", 0)
    nameLabel.text = "%s [DEAD]" % displayName
    _lastRenderedHealth = 0
    # Stop the anim tree before ragdoll so they don't fight over bone poses.
    if animTree != null:
        animTree.active = false
    _start_ragdoll()
    var hitBody: Node = get_node_or_null("HitBody")
    if hitBody != null:
        hitBody.collision_layer = 0
        hitBody.remove_from_group(&"CoopRemote")


## Uses Ragdoll.gd's ActivateBones helper when attached (it also unlocks each
## bone's axis locks); falls back to the raw Skeleton3D API otherwise.
func _start_ragdoll() -> void:
    if skeleton == null:
        return
    if skeleton.has_method(&"ActivateBones"):
        skeleton.ActivateBones()
    else:
        skeleton.physical_bones_start_simulation()


func _physics_process(delta: float) -> void:
    if !is_instance_valid(_cm) || isDead:
        return
    global_position = targetPosition
    rotation.y = targetRotationY
    _apply_spine_pitch(delta)
    _apply_flashlight()

    _update_anim_blend(delta)

    if Engine.get_physics_frames() % OCCLUSION_CHECK_TICKS == 0:
        _update_occlusion()

    var health: int = get_meta(&"health", -1)
    if health != _lastRenderedHealth:
        _lastRenderedHealth = health
        if health >= 0:
            nameLabel.text = "%s [%d%%]" % [displayName, health]
        else:
            nameLabel.text = displayName


## Mirrors the remote's flashlight toggle. Spotlight is created lazily and
## parented to a Head BoneAttachment3D so it tracks the skull (+ spine pitch
## override above) without us having to drive a transform every tick.
func _apply_flashlight() -> void:
    var wanted: bool = (moveFlags & _moveFlag.FLASHLIGHT) != 0
    if wanted == _flashlightOn:
        return
    _flashlightOn = wanted
    if _flashlight == null:
        if !wanted || skeleton == null:
            return
        _flashlightMount = BoneAttachment3D.new()
        _flashlightMount.bone_name = HEAD_BONE_NAME
        skeleton.add_child(_flashlightMount)
        _flashlight = SpotLight3D.new()
        _flashlight.spot_angle = 30.0
        _flashlight.spot_range = 50.0
        _flashlight.light_energy = 20.0
        _flashlight.shadow_enabled = false
        # Head bone forward = +Z in this rig; flip so the cone shines ahead.
        _flashlight.rotate_y(PI)
        _flashlightMount.add_child(_flashlight)
    _flashlight.visible = wanted


## Bends the spine to match the remote's camera pitch so aiming direction
## reads at a glance. Mirrors AI.Spine() but without the full look-at rig —
## we only have the pitch scalar, not a 3D target point.
func _apply_spine_pitch(delta: float) -> void:
    if skeleton == null || _spineBone < 0:
        return
    _spinePitch = lerpf(_spinePitch, targetRotationX, clampf(delta * 8.0, 0.0, 1.0))
    var pose: Transform3D = skeleton.get_bone_global_pose_no_override(_spineBone)
    pose.basis = pose.basis.rotated(pose.basis.x, -_spinePitch * SPINE_PITCH_WEIGHT)
    skeleton.set_bone_global_pose_override(_spineBone, pose, 1.0, true)


## Flags → target blend position (idle/walk/run/sprint). Lerp hides the 20 Hz
## packet cadence so transitions stay smooth.
func _update_anim_blend(delta: float) -> void:
    if animTree == null:
        return
    var flags: int = moveFlags
    var moving: bool = (flags & _moveFlag.MOVING) != 0
    var walking: bool = (flags & _moveFlag.WALKING) != 0
    var running: bool = (flags & _moveFlag.RUNNING) != 0

    if !moving:
        targetSpeed = SPEED_IDLE
    elif running:
        targetSpeed = SPEED_SPRINT
    elif walking:
        targetSpeed = SPEED_WALK
    else:
        targetSpeed = SPEED_RUN

    currentSpeed = lerpf(currentSpeed, targetSpeed, clampf(delta * 8.0, 0.0, 1.0))
    animTree[ANIM_PARAM_MOVEMENT_BLEND] = currentSpeed


## [param rot] packs (yaw=x, pitch=y) to reuse the existing 3-float RPC slot.
func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags


func play_remote_audio(audioPath: String) -> void:
    if !is_instance_valid(audioPlayer):
        return
    if !audioPath.begins_with("res://Resources/") && !audioPath.begins_with("res://Audio/"):
        return
    var audioEvent: Resource = load(audioPath)
    if audioEvent == null || !audioEvent.has_method(&"get"):
        return
    if audioEvent.audioClips.is_empty():
        return
    audioPlayer.bus = occludedBusName if isOccluded && occludedBusIdx >= 0 else &"Master"
    audioPlayer.stream = audioEvent.audioClips.pick_random()
    audioPlayer.volume_db = audioEvent.volume
    audioPlayer.pitch_scale = randf_range(0.9, 1.0) if audioEvent.randomPitch else 1.0
    audioPlayer.play()


var hitDefaultScene: PackedScene = preload("res://Effects/Hit_Default.tscn")
var hitKnifeScene: PackedScene = preload("res://Effects/Hit_Knife.tscn")


func spawn_bullet_impact(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var hit: Node3D = hitDefaultScene.instantiate()
    scene.add_child(hit)
    hit.global_position = hitPoint

    if hitNormal == Vector3(0, 1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    elif hitNormal == Vector3(0, -1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    else:
        hit.look_at(hitPoint + hitNormal, Vector3.DOWN)
    hit.global_rotation.z = randf_range(-360, 360)

    hit.Emit()
    hit.PlayHit(hitSurface)


func play_knife_attack(isSlash: bool) -> void:
    if !is_instance_valid(_cm):
        return
    var audioEvent: AudioEvent = _cm.audioLibrary.knifeSlash if isSlash else _cm.audioLibrary.knifeStab
    if audioEvent == null || audioEvent.audioClips.is_empty():
        return
    if !is_instance_valid(audioPlayer):
        return
    audioPlayer.stream = audioEvent.audioClips.pick_random()
    audioPlayer.volume_db = audioEvent.volume
    audioPlayer.play()


func spawn_knife_impact(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String, isFlesh: bool, attackId: int) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var decal: Node3D = hitKnifeScene.instantiate()
    scene.add_child(decal)
    decal.global_position = hitPoint

    if hitNormal == Vector3(0, 1, 0):
        decal.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    elif hitNormal == Vector3(0, -1, 0):
        decal.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    else:
        decal.look_at(hitPoint + hitNormal, Vector3.DOWN)

    # Angles match KnifeRig.KnifeDecal per combo index.
    match attackId:
        1: decal.global_rotation_degrees.z = 30.0
        2: decal.global_rotation_degrees.z = 10.0
        3: decal.global_rotation_degrees.z = -10.0
        4: decal.global_rotation_degrees.z = -30.0
        5: decal.global_rotation_degrees.z = 15.0
        6: decal.global_rotation_degrees.z = 0.0
        7: decal.global_rotation_degrees.z = -30.0
        8: decal.global_rotation_degrees.z = 45.0

    if isFlesh:
        decal.PlayKnifeHitFlesh(attackId)
    else:
        decal.PlayKnifeHit(hitSurface)


func play_fire_event(fireAudio: String, tailAudio: String, showFlash: bool) -> void:
    play_remote_audio(fireAudio)

    # Tail audio on its own player so it doesn't cut the fire sound.
    if !tailAudio.is_empty():
        var tailEvent: Resource = load(tailAudio)
        if tailEvent != null && !tailEvent.audioClips.is_empty():
            var tailPlayer: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
            tailPlayer.max_distance = 100.0
            tailPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
            add_child(tailPlayer)
            tailPlayer.stream = tailEvent.audioClips.pick_random()
            tailPlayer.volume_db = tailEvent.volume
            if isOccluded && occludedBusIdx >= 0:
                tailPlayer.bus = occludedBusName
            tailPlayer.play()
            tailPlayer.finished.connect(tailPlayer.queue_free)

    # Reposition the super rig's Flash to the active muzzle and pulse it —
    # matches AI.gd per-shot flash handling.
    if showFlash && is_instance_valid(flashNode) && is_instance_valid(activeMuzzle):
        flashNode.global_position = activeMuzzle.global_position
        if flashNode.has_method(&"Activate"):
            flashNode.Activate()
