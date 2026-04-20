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

## Mirrors the remote peer's [code]gameData.isFiring[/code]. Decoded from
## the [enum PlayerState.MoveFlag.FIRING] bit on every state snapshot in
## [method update_state] so AI's FireDetection sees a held-trigger semi-auto
## burst the same way it sees the host's local firing — no decay window
## approximation needed.
var isFiring: bool = false

var audioPlayer: AudioStreamPlayer3D = null

var occlusionRay: PhysicsRayQueryParameters3D = null
var isOccluded: bool = false
const OCCLUSION_CHECK_TICKS: int = 24
const OCCLUSION_DB_PENALTY: float = -8.0
const OCCLUSION_CUTOFF_HZ: float = 800.0
static var occludedBusName: StringName = &""
static var occludedBusIdx: int = -1

## Puppet AI scene held as a child. Hosts the skeleton/mesh/weapons/animator
## refs we read out of [code]ai_patch.gd[/code]'s @onready vars. Same node as
## [member modelRoot] — kept under both names while the codebase migrates off
## the older "modelRoot" terminology.
var aiInstance: Node3D = null
var modelRoot: Node3D = null
var animTree: AnimationTree = null
## AnimationPlayer drives the rig bones directly per remote_player. Cleaner +
## cheaper than driving the AnimationTree with all its blend conditions.
var animPlayer: AnimationPlayer = null
var currentAnim: StringName = &""
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
## Currently loaded body — empty until first [method set_appearance]. Comparing
## against the incoming body lets [method set_appearance] skip rig reloads when
## only the material changes.
var currentBody: String = ""
## The single skinned mesh for the currently-loaded body. Each AI rig has one
## MeshInstance3D under its Skeleton3D; we keep a direct ref for material swap.
var meshNode: MeshInstance3D = null
var flashNode: Node3D = null
var activeWeapon: Node3D = null
var activeMuzzle: Node3D = null

const PATH_COLLISION: NodePath = ^"Collision"
const PATH_ANIMATIONS: NodePath = ^"Animations"
const PATH_MUZZLE: NodePath = ^"Muzzle"
const PATH_HITBODY: NodePath = ^"HitBody"
const PATH_LOCAL_CONTROLLER: NodePath = ^"Core/Controller"

## Per-body source scene. Each AI rig (Bandit/Guard/Military/Punisher) carries
## a skeleton tuned to its own mesh — instantiating the source scene per-peer
## avoids the bone-weight clamping that bit the merged super_rig.scn approach.
const BODY_SCENES: Dictionary[String, String] = {
    "Bandit": "res://AI/Bandit/AI_Bandit.tscn",
    "Guard": "res://AI/Guard/AI_Guard.tscn",
    "Military": "res://AI/Military/AI_Military.tscn",
    "Punisher": "res://AI/Punisher/AI_Punisher.tscn",
}

## Scene-root children to purge from each AI rig instance — same set as the
## old build_super_rig.gd EditorScript. Collision + Flash kept (used for hit
## reg + muzzle flash).
const SCENE_TRASH: Array[String] = ["Detector", "Raycasts", "Poles", "Gizmo", "Agent"]
## Skeleton3D children to purge per rig.
const SKEL_TRASH: Array[String] = [
    "Container", "Eyes", "Backpacks",
    "HB_Head", "HB_Torso",
    "HB_Leg_Upper_L", "HB_Leg_Lower_L",
    "HB_Leg_Upper_R", "HB_Leg_Lower_R",
]

## Animation clips on the AI rig's AnimationPlayer (Bandit/Guard/Military/
## Punisher all share the same Rifle_* / Pistol_* clip names). Picked per
## movement-flag state in [method _update_anim_blend].
const ANIM_RIFLE_IDLE: StringName = &"Rifle_Idle"
const ANIM_RIFLE_WALK: StringName = &"Rifle_Walk_F"
const ANIM_RIFLE_RUN: StringName = &"Rifle_Aim_Run_F"
const ANIM_RIFLE_SPRINT: StringName = &"Rifle_Sprint_F"
const ANIM_BLEND: float = 0.3

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

    var defaults: Dictionary = _cm.AppearanceScript.get_defaults()
    set_appearance(defaults.body, defaults.material)


## Instantiates the per-body AI scene as a puppet rig — keeps the AI script
## attached but flips [code]puppetMode = true[/code] on it so all sensor /
## navigation / animator logic short-circuits. Then strips the children we
## don't need (sensors, hitboxes, container, root collision shape) and uses
## the AI script's [code]@onready[/code] refs (skeleton/mesh/weapons/animator/
## eyes/flash) directly instead of walking node paths ourselves.
func _spawn_puppet_rig(body: String) -> bool:
    if !BODY_SCENES.has(body):
        return false
    var packed: PackedScene = load(BODY_SCENES[body]) as PackedScene
    if packed == null:
        push_warning("[remote_player] failed to load AI scene for body=%s" % body)
        return false
    var ai: Node3D = packed.instantiate() as Node3D
    if ai == null:
        return false

    # Mark as puppet BEFORE add_child so AI._ready / Initialize see the flag
    # and skip their normal setup paths.
    ai.set(&"puppetMode", true)

    # Inert collision body — host AI normally is a CharacterBody3D in mask
    # layers. Our hit detection uses a separate StaticBody3D in COOP_HIT_LAYER
    # below, not this one.
    if ai is CollisionObject3D:
        var co: CollisionObject3D = ai
        co.collision_layer = 0
        co.collision_mask = 0
    # Drop AI / interactable groups so AISpawner pool scans + Interactor
    # raycasts both ignore the puppet.
    for g: StringName in ai.get_groups():
        ai.remove_from_group(g)

    # Strip nodes we'll never use on a puppet. SCENE_TRASH lives at the rig
    # root (sensors, navigation agent, debug gizmos). Skeleton-level junk
    # (container, eyes, backpacks, hitbox attachments) gets stripped after
    # the AI script's @onready refs resolve.
    for trash: String in SCENE_TRASH:
        var n: Node = ai.get_node_or_null(trash)
        if n != null:
            n.get_parent().remove_child(n)
            n.queue_free()
    var rootCollision: Node = ai.get_node_or_null(PATH_COLLISION)
    if rootCollision != null:
        rootCollision.get_parent().remove_child(rootCollision)
        rootCollision.queue_free()

    add_child(ai)
    aiInstance = ai

    # AI script's @onready vars are populated by now (after add_child).
    # ai_patch.gd._ready already flipped set_physics_process(false) +
    # set_process(false) since puppetMode was set before add_child fired.
    skeleton = ai.get(&"skeleton") as Skeleton3D
    meshNode = ai.get(&"mesh") as MeshInstance3D
    var weapons: Node = ai.get(&"weapons")
    flashNode = ai.get(&"flash") as Node3D
    animTree = ai.get(&"animator") as AnimationTree
    # Skeleton-level trash strip (container, eyes, backpacks, hit boxes).
    if skeleton != null:
        for trash: String in SKEL_TRASH:
            var n: Node = skeleton.get_node_or_null(trash)
            if n != null:
                n.get_parent().remove_child(n)
                n.queue_free()
        skeleton.show_rest_only = false
        skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

    # AnimationTree is fragile — its blend conditions need to match exactly
    # what the AI script would set per-state, otherwise the rig snaps to
    # broken poses. AnimationPlayer drives clips directly; simpler + cheaper.
    if animTree != null:
        animTree.active = false
    animPlayer = _find_anim_player(ai)

    # Spine bone index lookup matches the AI script's spineData if present
    # (saves a find_bone walk + matches whatever the rig was authored with).
    var spineData: Variant = ai.get(&"spineData")
    if spineData != null && spineData.get(&"bone") != null:
        _spineBone = int(spineData.bone)
    elif skeleton != null:
        _spineBone = skeleton.find_bone(SPINE_BONE_NAME)

    if weapons != null:
        for w: Node in weapons.get_children():
            _strip_baked_weapon(w)

    modelRoot = ai
    _play_anim(ANIM_RIFLE_IDLE)
    currentBody = body
    return true


## Walks the AI scene to find its AnimationPlayer. Authored layout puts it at
## "<BodyName>/Animations" (sibling of the Skeleton3D's Armature parent).
static func _find_anim_player(ai: Node) -> AnimationPlayer:
    for child: Node in ai.get_children():
        if child is Node3D:
            var found: AnimationPlayer = child.get_node_or_null(PATH_ANIMATIONS) as AnimationPlayer
            if found != null:
                return found
    return null


## Frees the current rig + its references so [method _load_body_rig] can
## install a new one. Called when the appearance RPC names a different body.
func _free_current_rig() -> void:
    if is_instance_valid(aiInstance):
        aiInstance.queue_free()
    aiInstance = null
    modelRoot = null
    skeleton = null
    animTree = null
    animPlayer = null
    currentAnim = &""
    flashNode = null
    meshNode = null
    activeWeapon = null
    activeMuzzle = null
    _spineBone = -1
    _flashlight = null
    _flashlightMount = null
    _flashlightOn = false
    currentBody = ""


## Baked weapons under super_rig retain their source RigidBody3D + "Item"
## group, which makes Interactor pick them up through the local player's body.
## Disable physics + groups so they're purely visual.
static func _strip_baked_weapon(node: Node) -> void:
    for g: StringName in node.get_groups():
        node.remove_from_group(g)
    if node is RigidBody3D:
        var rb: RigidBody3D = node
        rb.freeze = true
        rb.collision_layer = 0
        rb.collision_mask = 0
    elif node is CollisionObject3D:
        var co: CollisionObject3D = node
        co.collision_layer = 0
        co.collision_mask = 0
    for child: Node in node.get_children():
        _strip_baked_weapon(child)


## Equipment-sync entry point. Empty [param weaponName] clears the attachment.
func set_active_weapon(weaponName: String) -> void:
    if aiInstance == null:
        return
    var weapons: Node = aiInstance.get(&"weapons")
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
    # The AI rig already bundles every weapon its source AI carries under the
    # Weapons BoneAttachment3D (with the authored Hand_R transform). Flip the
    # matching one visible if present; otherwise dynamic-attach below.
    var baked: Node3D = weapons.get_node_or_null(weaponName) as Node3D
    if baked != null:
        baked.visible = true
        activeWeapon = baked
        activeMuzzle = baked.get_node_or_null(PATH_MUZZLE) as Node3D
        return
    _attach_dynamic_weapon(weapons, weaponName)


## Cache of authored hand-slot transforms harvested from every AI rig's
## Weapons BoneAttachment3D. When a peer's loaded body doesn't bundle the
## requested weapon, we still grip it with the original Transform3D the
## designer authored on a sibling rig — only falls back to the class-wide
## RIFLE / PISTOL grip when no rig bundles it (HK416, MK18, MP7, etc.).
static var _handSlotTransforms: Dictionary[String, Transform3D] = {}
static var _handSlotsBuilt: bool = false


## Lazily walks every AI rig's Weapons attachment and snapshots each child's
## Transform3D by name. Runs once per session — first dynamic-attach miss
## triggers it, subsequent attaches read from the cache.
static func _ensure_hand_slots() -> void:
    if _handSlotsBuilt:
        return
    _handSlotsBuilt = true
    for body: String in BODY_SCENES:
        var bodyPath: String = BODY_SCENES[body]
        var packed: PackedScene = load(bodyPath) as PackedScene
        if packed == null:
            continue
        var inst: Node = packed.instantiate()
        if inst == null:
            continue
        var weaponsNode: Node = inst.get_node_or_null("%s/Armature/Skeleton3D/Weapons" % body)
        if weaponsNode != null:
            for w: Node in weaponsNode.get_children():
                if w is Node3D && !_handSlotTransforms.has(w.name):
                    _handSlotTransforms[w.name] = (w as Node3D).transform
        inst.free()


## Instantiates a weapon scene on demand for names not bundled in this peer's
## rig. Uses the authored hand-slot transform from another AI rig if available,
## else a class-wide pistol/rifle fallback.
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
    _strip_baked_weapon(weapon)

    var slot: Transform3D = Transform3D.IDENTITY
    var slotFound: bool = false
    _ensure_hand_slots()
    if _handSlotTransforms.has(weaponName):
        slot = _handSlotTransforms[weaponName]
        slotFound = true
    if !slotFound:
        var isPistol: bool = false
        if weapon.has_method(&"get") && weapon.get(&"slotData") != null:
            var data: Resource = weapon.slotData.itemData if weapon.slotData != null else null
            if data != null && data.get(&"weaponType") == "Pistol":
                isPistol = true
        slot = FALLBACK_PISTOL_GRIP if isPistol else FALLBACK_RIFLE_GRIP
    if weapon is Node3D:
        (weapon as Node3D).transform = slot
    weapons.add_child(weapon)
    activeWeapon = weapon as Node3D
    activeMuzzle = weapon.get_node_or_null(PATH_MUZZLE) as Node3D


## Allowlist for weapon file names — prevents path traversal / arbitrary load
## through the equipment RPC.
static func _is_valid_weapon_name(weapon_name: String) -> bool:
    if weapon_name.length() > 32:
        return false
    for i: int in weapon_name.length():
        var c: int = weapon_name.unicode_at(i)
        var ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
        if !ok:
            return false
    return true


func set_appearance(body: String, materialPath: String) -> void:
    if !_cm.AppearanceScript.is_valid({"body": body, "material": materialPath}):
        return

    # Body change → free old rig + load new. Material change only → keep rig,
    # just re-apply the material below. set_appearance fires twice on spawn
    # (default body, then cached/RPC body) so the second call may swap the rig.
    if body != currentBody:
        _free_current_rig()
        if !_spawn_puppet_rig(body):
            return

    if !is_instance_valid(meshNode):
        return
    var mat: Material = _load_material(materialPath)
    if mat == null:
        return
    var surfaceCount: int = meshNode.mesh.get_surface_count() if meshNode.mesh != null else 0
    for i: int in surfaceCount:
        meshNode.set_surface_override_material(i, mat)


func _load_material(path: String) -> Material:
    var cached: Material = null
    if _materialCache.has(path):
        cached = _materialCache[path]
    if cached != null:
        return cached
    var mat: Material = load(path) as Material
    if mat != null:
        _materialCache[path] = mat
    return mat


## Plays [param clip] on the rig's AnimationPlayer with a fixed crossfade.
## Skips when the clip is already playing to avoid restarting the same loop.
func _play_anim(clip: StringName) -> void:
    if animPlayer == null || clip == currentAnim:
        return
    if !animPlayer.has_animation(clip):
        return
    animPlayer.play(clip, ANIM_BLEND)
    currentAnim = clip


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
    # Stop the animator before ragdoll so they don't fight over bone poses.
    if animPlayer != null:
        animPlayer.stop()
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
##
## Skip-on-zero: applying a "rotate by 0" override still REPLACES animator's
## pose for Spine_03 every frame. With native AI rigs the animator hasn't
## necessarily ticked when the first pitch sample lands, so the pose we read
## back can be the rest pose — pinning spine to the rest pose stretches the
## torso mesh because Arm/Head bones still animate relative to it. Until we
## actually receive a non-zero pitch (peer aiming up/down), let the animator
## drive Spine_03 unmodified.
func _apply_spine_pitch(delta: float) -> void:
    if skeleton == null || _spineBone < 0:
        return
    if absf(targetRotationX) < 0.001 && absf(_spinePitch) < 0.001:
        return
    _spinePitch = lerpf(_spinePitch, targetRotationX, clampf(delta * 8.0, 0.0, 1.0))
    var pose: Transform3D = skeleton.get_bone_global_pose_no_override(_spineBone)
    pose.basis = pose.basis.rotated(pose.basis.x, -_spinePitch * SPINE_PITCH_WEIGHT)
    skeleton.set_bone_global_pose_override(_spineBone, pose, 1.0, true)


## Animation tracks on the AI rig call PlayFootstep / PlayCombat / etc on the
## scene root via NodePath "..". With puppetMode the AI script is still
## attached, so those methods exist natively — no stubs needed here.

## Flags → named animation clip. Plays Rifle_Idle / Walk / Run / Sprint on the
## AnimationPlayer directly — swapped lazily via [method _play_anim].
func _update_anim_blend(_delta: float) -> void:
    if animPlayer == null:
        return
    var flags: int = moveFlags
    var moving: bool = (flags & _moveFlag.MOVING) != 0
    var walking: bool = (flags & _moveFlag.WALKING) != 0
    var running: bool = (flags & _moveFlag.RUNNING) != 0

    var clip: StringName = ANIM_RIFLE_IDLE
    if moving:
        if running:
            clip = ANIM_RIFLE_SPRINT
        elif walking:
            clip = ANIM_RIFLE_WALK
        else:
            clip = ANIM_RIFLE_RUN
    _play_anim(clip)


## [param rot] packs (yaw=x, pitch=y) to reuse the existing 3-float RPC slot.
func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags
    isFiring = (flags & _moveFlag.FIRING) != 0


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
