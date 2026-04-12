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

var audioPlayer: AudioStreamPlayer3D = null


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

    nameLabel.text = name
    targetPosition = global_position

    audioPlayer = AudioStreamPlayer3D.new()
    audioPlayer.max_distance = 50.0
    audioPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
    add_child(audioPlayer)

    # Collision body for AI raycasts (LOS + fire) to detect this remote player
    _create_collision_body()
    # Groups for AI detection: "CoopRemote" for the patch, "Player" for the detector Area3D
    add_to_group("CoopRemote")
    add_to_group("Player")


## Creates a StaticBody3D with a capsule collider matching the body mesh.
## The body is in the "CoopRemote" and "Player" groups so AI raycasts recognize it.
func _create_collision_body() -> void:
    var staticBody: StaticBody3D = StaticBody3D.new()
    staticBody.name = "HitBody"
    staticBody.add_to_group("CoopRemote")
    staticBody.add_to_group("Player")
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


func _physics_process(delta: float) -> void:
    if !is_instance_valid(_cm):
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

    # Update name label with health if available
    var health: int = get_meta(&"health", -1)
    if health >= 0:
        nameLabel.text = "%s [%d%%]" % [name, health]


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
    if audioEvent == null || !audioEvent.has_method("get"):
        return
    if audioEvent.audioClips.is_empty():
        return
    audioPlayer.stream = audioEvent.audioClips.pick_random()
    audioPlayer.volume_db = audioEvent.volume
    audioPlayer.pitch_scale = randf_range(0.9, 1.0) if audioEvent.randomPitch else 1.0
    audioPlayer.play()


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
        get_tree().create_timer(0.05).timeout.connect(light.queue_free)
