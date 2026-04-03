## Ghost visual representing a remote co-op player.
## Receives interpolated state from [code]PlayerState[/code] via [method UpdateState].
## Never reads [code]GameData[/code] directly.
extends Node3D

const PlayerStateScript = preload("res://mod/network/player_state.gd")

var targetPosition: Vector3 = Vector3.ZERO
var targetRotationY: float = 0.0
var targetRotationX: float = 0.0
var moveFlags: int = 0
var smoothSpeed: float = 15.0

var audioLibrary: AudioLibrary = preload("res://Resources/AudioLibrary.tres")
var audioPlayer: AudioStreamPlayer3D = null

@onready var body: MeshInstance3D = $Body
@onready var headPivot: Node3D = $HeadPivot
@onready var headMesh: MeshInstance3D = $HeadPivot/HeadMesh
@onready var nameLabel: Label3D = $NameLabel


func _ready() -> void:
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


func _physics_process(delta: float) -> void:
    global_position = global_position.lerp(targetPosition, delta * smoothSpeed)

    rotation.y = lerp_angle(rotation.y, targetRotationY, delta * smoothSpeed)
    headPivot.rotation.x = lerp_angle(
        headPivot.rotation.x,
        targetRotationX,
        delta * smoothSpeed,
    )

    if moveFlags & PlayerStateScript.MoveFlag.CROUCHING:
        body.scale.y = lerpf(body.scale.y, 0.6, delta * 5.0)
        headPivot.position.y = lerpf(headPivot.position.y, 1.0, delta * 5.0)
    else:
        body.scale.y = lerpf(body.scale.y, 1.0, delta * 5.0)
        headPivot.position.y = lerpf(headPivot.position.y, 1.6, delta * 5.0)


## Applies a network state snapshot. Called by the interpolation loop in [code]PlayerState[/code].
## [param pos]: world position. [param rot]: packed rotation (x=yaw, y=pitch). [param flags]: [enum MoveFlag] bitfield.
func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags


## Plays a spatial audio event at this remote player's position.
func play_remote_audio(audioPath: String) -> void:
    if audioPlayer == null:
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
