## Ghost visual representing a remote co-op player.
## Receives interpolated state from [code]PlayerState[/code] via [method UpdateState].
## Never reads [code]GameData[/code] directly.
extends Node3D

var _cm: Node


var targetPosition: Vector3 = Vector3.ZERO
var targetRotationY: float = 0.0
var targetRotationX: float = 0.0
var moveFlags: int = 0
var smoothSpeed: float = 15.0
var displayName: String = ""
var isDead: bool = false

var audioPlayer: AudioStreamPlayer3D = null

## Occlusion state
var occlusionRay: PhysicsRayQueryParameters3D = null
var isOccluded: bool = false
const OCCLUSION_CHECK_TICKS: int = 24  ## ~5Hz at 120Hz physics
const OCCLUSION_DB_PENALTY: float = -8.0
const OCCLUSION_CUTOFF_HZ: float = 800.0
static var occludedBusName: StringName = &""
static var occludedBusIdx: int = -1

@onready var body: MeshInstance3D = $Body
@onready var headPivot: Node3D = $HeadPivot
@onready var headMesh: MeshInstance3D = $HeadPivot/HeadMesh
@onready var nameLabel: Label3D = $NameLabel


func init_manager(manager: Node) -> void:
    _cm = manager
    var bodyMat: StandardMaterial3D = StandardMaterial3D.new()
    bodyMat.albedo_color = Color(0.2, 0.6, 0.3, 0.8)
    bodyMat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    body.material_override = bodyMat

    var headMat: StandardMaterial3D = StandardMaterial3D.new()
    headMat.albedo_color = Color(0.8, 0.7, 0.5)
    headMesh.material_override = headMat

    displayName = name
    nameLabel.text = displayName
    targetPosition = global_position

    audioPlayer = AudioStreamPlayer3D.new()
    audioPlayer.max_distance = 50.0
    audioPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
    add_child(audioPlayer)

    _ensure_occluded_bus()

    # Collision body for AI raycasts (LOS + fire) to detect this remote player
    _create_collision_body()
    # Group for AI detection — ai_patch checks "CoopRemote" explicitly
    add_to_group("CoopRemote")


## Creates a StaticBody3D with a capsule collider matching the body mesh.
## The body is in the "CoopRemote" and "Player" groups so AI raycasts recognize it.
## Collision layer 20 (bit 19) — dedicated to co-op remote player hit detection.
## Only AI raycasts have this bit in their mask (set by ai_patch.gd).
## Keeps HitBody invisible to the Interactor, player weapons, and other systems.
const COOP_HIT_LAYER: int = 1 << 19


func _create_collision_body() -> void:
    var staticBody: StaticBody3D = StaticBody3D.new()
    staticBody.name = "HitBody"
    staticBody.collision_layer = COOP_HIT_LAYER
    staticBody.collision_mask = 0
    staticBody.add_to_group(&"CoopRemote")
    # Copy peer_id meta so ai_patch can find the peer from the collider
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


## Creates the shared "CoopOccluded" audio bus with a lowpass filter.
## Called once per session — static vars persist across instances.
static func _ensure_occluded_bus() -> void:
    occludedBusName = &"CoopOccluded"
    # Look up by name every time — bus indices can shift at runtime
    var idx: int = AudioServer.get_bus_index(occludedBusName)
    if idx >= 0:
        occludedBusIdx = idx
        return
    # Create new bus
    AudioServer.add_bus()
    occludedBusIdx = AudioServer.bus_count - 1
    AudioServer.set_bus_name(occludedBusIdx, occludedBusName)
    AudioServer.set_bus_send(occludedBusIdx, &"Master")
    AudioServer.set_bus_volume_db(occludedBusIdx, OCCLUSION_DB_PENALTY)
    var lpf: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
    lpf.cutoff_hz = OCCLUSION_CUTOFF_HZ
    AudioServer.add_bus_effect(occludedBusIdx, lpf)


## Raycasts from listener to this remote player. If geometry blocks LOS, route audio
## through the occluded bus (lowpass + volume reduction).
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
        # Exclude local player's body so the ray doesn't immediately hit it
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
    # Collapse the body visually.
    body.scale.y = 0.15
    headPivot.position.y = 0.2
    headPivot.rotation.x = -PI / 2.0
    # Disable AI hit detection so AI stops targeting the corpse.
    var hitBody: Node = get_node_or_null("HitBody")
    if hitBody != null:
        hitBody.collision_layer = 0
        hitBody.remove_from_group(&"CoopRemote")


func _physics_process(delta: float) -> void:
    if !is_instance_valid(_cm) || isDead:
        return
    global_position = targetPosition
    rotation.y = targetRotationY
    headPivot.rotation.x = targetRotationX

    if moveFlags & _cm.PlayerStateScript.MoveFlag.CROUCHING:
        body.scale.y = lerpf(body.scale.y, 0.6, delta * 5.0)
        headPivot.position.y = lerpf(headPivot.position.y, 1.0, delta * 5.0)
    else:
        body.scale.y = lerpf(body.scale.y, 1.0, delta * 5.0)
        headPivot.position.y = lerpf(headPivot.position.y, 1.6, delta * 5.0)

    # Occlusion check at ~5Hz
    if Engine.get_physics_frames() % OCCLUSION_CHECK_TICKS == 0:
        _update_occlusion()

    var health: int = get_meta(&"health", -1)
    if health >= 0:
        nameLabel.text = "%s [%d%%]" % [displayName, health]
    else:
        nameLabel.text = displayName


## Applies a network state snapshot. Called by the interpolation loop in [code]PlayerState[/code].
## [param pos]: world position. [param rot]: packed rotation (x=yaw, y=pitch). [param flags]: [enum MoveFlag] bitfield.
func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags


## Plays a spatial audio event at this remote player's position.
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


## Spawns a bullet impact decal + particle at the given world position.
## Parented to the current scene root so it stays in world space.
func spawn_bullet_impact(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var hit: Node3D = hitDefaultScene.instantiate()
    scene.add_child(hit)
    hit.global_position = hitPoint

    # Orient decal by normal (same logic as WeaponRig.HitEffect)
    if hitNormal == Vector3(0, 1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    elif hitNormal == Vector3(0, -1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    else:
        hit.look_at(hitPoint + hitNormal, Vector3.DOWN)
    hit.global_rotation.z = randf_range(-360, 360)

    hit.Emit()
    hit.PlayHit(hitSurface)


## Plays a knife attack audio event spatially.
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


## Spawns a knife hit decal at the impact point.
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

    # Rotation by attack type (matches KnifeRig.KnifeDecal)
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


## Plays a weapon fire event: gunshot audio, optional tail audio, and muzzle flash.
func play_fire_event(fireAudio: String, tailAudio: String, showFlash: bool) -> void:
    # Play fire audio
    play_remote_audio(fireAudio)

    # Play tail audio on a separate player so it doesn't cut the fire sound
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

    # Muzzle flash light (unsuppressed only)
    if showFlash:
        var light: OmniLight3D = OmniLight3D.new()
        light.light_color = Color(1.0, 0.8, 0.4)
        light.light_energy = 2.0
        light.omni_range = 8.0
        light.position = Vector3(0, 1.4, -0.3)
        add_child(light)
        get_tree().create_timer(0.05).timeout.connect(_free_if_valid.bind(light))


static func _free_if_valid(node: Node) -> void:
    if is_instance_valid(node):
        node.queue_free()
