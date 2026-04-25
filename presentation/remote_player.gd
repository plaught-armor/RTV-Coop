## Base class for remote player visuals; subclasses choose rig style
## ([code]remote_player_puppet.gd[/code] = AI rig, [code]remote_player_capsule.gd[/code] = bare capsule + FPS arms).
## Owns shared snapshot state, audio + occlusion bus, hit collision body, name
## label / health overlay, decals, and fire-event audio. Subclasses fill in
## rig spawn / weapon attach / per-frame skeletal updates / ragdoll via the
## virtual hooks below.
extends Node3D


# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")


# Bit 19: ai_patch adds only this bit to fire/LOS masks so HitBody is invisible to everything else.
const COOP_HIT_LAYER: int = 1 << 19

const PATH_MUZZLE: NodePath = ^"Muzzle"
const PATH_HITBODY: NodePath = ^"HitBody"
const PATH_LOCAL_CONTROLLER: NodePath = ^"Core/Controller"

const OCCLUSION_CHECK_TICKS: int = 24
const OCCLUSION_DB_PENALTY: float = -8.0
const OCCLUSION_CUTOFF_HZ: float = 800.0


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
var _moveFlag: Dictionary = {}
# set_appearance fires twice on spawn; cache avoids redundant .tres parses.
var _materialCache: Dictionary[String, Material] = {}

var audioPlayer: AudioStreamPlayer3D = null
var occlusionRay: PhysicsRayQueryParameters3D = null
var isOccluded: bool = false
var occludedBusName: StringName = &""
var occludedBusIdx: int = -1

# Concrete rig fields populated by subclass _spawn_rig.
var modelRoot: Node3D = null
var meshNode: MeshInstance3D = null
var activeWeapon: Node3D = null
var activeMuzzle: Node3D = null
var currentBody: String = ""
# StringName so _apply_attachments pointer-compares vs Attachments child names.
var _activeAttachments: Array[StringName] = []


@onready var nameLabel: Label3D = $NameLabel


func _ready() -> void:
    _moveFlag = CoopManager.PlayerStateScript.MoveFlag
    nameLabel.text = displayName
    targetPosition = global_position

    audioPlayer = AudioStreamPlayer3D.new()
    audioPlayer.max_distance = 50.0
    audioPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
    add_child(audioPlayer)

    _ensure_occluded_bus()
    _create_collision_body()
    add_to_group(&"CoopRemote")

    var defaults: Dictionary = CoopManager.appearance.get_defaults()
    # Capsule subclass rejects non-Capsule bodies (and vice versa) so the
    # default-load only fires when the cached scene matches the family.
    if accepts_body(defaults.body):
        set_appearance(defaults.body, defaults.material)


# Virtual: subclass declares which body family it can render.
func accepts_body(_body: String) -> bool:
    return false


# Virtual: subclass instantiates concrete rig + populates modelRoot/meshNode/currentBody.
func _spawn_rig(_body: String) -> bool:
    return false


# Virtual: subclass frees instantiated rig + resets references.
func _free_rig() -> void:
    pass


# Virtual: subclass per-frame skeletal updates (spine pitch, anim blend, flashlight).
func _apply_visuals(_delta: float) -> void:
    pass


# Virtual: subclass ragdoll / death pose handling.
func _start_ragdoll() -> void:
    pass


# Virtual: subclass attaches weapon model (baked AI rig vs FPS rig).
func set_active_weapon(_weaponName: String) -> void:
    pass


# Virtual: optional muzzle flash hook fired by play_fire_event.
func _pulse_muzzle_flash() -> void:
    pass


func is_capsule_body() -> bool:
    return currentBody == "Capsule"


func set_appearance(body: String, materialPath: String) -> void:
    if !CoopManager.appearance.is_valid({"body": body, "material": materialPath}):
        return
    if !accepts_body(body):
        return

    # Body change → free old rig + load new. Material change only → keep rig,
    # just re-apply the material below. set_appearance fires twice on spawn
    # (default body, then cached/RPC body) so the second call may swap the rig.
    if body != currentBody:
        _free_rig()
        if !_spawn_rig(body):
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
    if !ResourceLoader.exists(path):
        return null
    var mat: Material = load(path) as Material
    if mat != null:
        _materialCache[path] = mat
    return mat


## Equipment-sync entry for attachments. Mirrors [method Pickup._ready]'s
## attachment reveal: walks the active weapon's [code]Attachments[/code] child,
## hides every attachment node, then [code].show()[/code]s the ones whose
## [code]name[/code] matches the incoming [StringName] list.
func set_active_attachments(names: Array[StringName]) -> void:
    _activeAttachments = names
    _apply_attachments()


func _apply_attachments() -> void:
    if !is_instance_valid(activeWeapon):
        return
    var attachmentsRoot: Node = activeWeapon.get_node_or_null(^"Attachments")
    if attachmentsRoot == null:
        return
    for child: Node in attachmentsRoot.get_children():
        if child is Node3D:
            (child as Node3D).visible = false
    for stem: StringName in _activeAttachments:
        var node: Node = attachmentsRoot.get_node_or_null(NodePath(stem))
        if node is Node3D:
            (node as Node3D).visible = true
            # Update activeMuzzle so fire-event flashes use the equipped muzzle
            # instead of the bare-barrel Muzzle node.
            var candidate: Node3D = node.get_node_or_null(PATH_MUZZLE) as Node3D
            if candidate != null:
                activeMuzzle = candidate


## Allowlist for weapon file names — prevents path traversal / arbitrary load.
func _is_valid_weapon_name(weapon_name: String) -> bool:
    if weapon_name.length() > 32:
        return false
    for i: int in weapon_name.length():
        var c: int = weapon_name.unicode_at(i)
        var ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
        if !ok:
            return false
    return true


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
## so name-based lookup beats caching the index across map loads.
func _ensure_occluded_bus() -> void:
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
        var controller: Node = get_tree().current_scene.get_node_or_null(PATH_LOCAL_CONTROLLER)
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
    _start_ragdoll()
    var hitBody: Node = get_node_or_null(PATH_HITBODY)
    if hitBody != null:
        hitBody.collision_layer = 0
        hitBody.remove_from_group(&"CoopRemote")


func _physics_process(delta: float) -> void:
    if !is_instance_valid(CoopManager) || isDead:
        return
    global_position = targetPosition
    rotation.y = targetRotationY
    _apply_visuals(delta)

    if Engine.get_physics_frames() % OCCLUSION_CHECK_TICKS == 0:
        _update_occlusion()

    var health: int = get_meta(&"health", -1)
    if health != _lastRenderedHealth:
        _lastRenderedHealth = health
        if health >= 0:
            nameLabel.text = "%s [%d%%]" % [displayName, health]
        else:
            nameLabel.text = displayName


func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags


## Single source of truth — callers read state via predicate to avoid drift
## between `moveFlags` and mirror bool vars.
func has_flag(flag: int) -> bool:
    return (moveFlags & flag) != 0


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
    if !is_instance_valid(CoopManager):
        return
    var audioEvent: AudioEvent = CoopManager.audioLibrary.knifeSlash if isSlash else CoopManager.audioLibrary.knifeStab
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

    if showFlash:
        _pulse_muzzle_flash()
