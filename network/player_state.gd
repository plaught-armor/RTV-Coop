## Handles player position, rotation, and movement flag synchronisation over ENet.
## Owned by [code]Node[/code] (added as a child node). All player-related RPCs live here.
extends Node

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager



## Bitfield values for encoding player movement state into a single [code]int[/code].
enum MoveFlag {
    MOVING = 1,
    WALKING = 2,
    RUNNING = 4,
    CROUCHING = 8,
    GROUNDED = 16,
}


## A single network state snapshot. Typed fields avoid hash lookups.
class Snapshot extends RefCounted:
    var timestamp: float
    var position: Vector3
    var rotation: Vector3
    var flags: int


    func _init(t: float = 0.0, p: Vector3 = Vector3.ZERO, r: Vector3 = Vector3.ZERO, f: int = 0) -> void:
        timestamp = t
        position = p
        rotation = r
        flags = f


## Per-peer ring buffer. Fixed-size, O(1) insert, no shifting.
## [member head] is the index of the oldest entry. [member count] tracks valid entries.
class PeerBuffer extends RefCounted:
    var seq: int = 0
    var slots: Array[Snapshot] = []
    var head: int = 0
    var count: int = 0
    var capacity: int = 0


    func _init(cap: int = 20) -> void:
        capacity = cap
        slots.resize(cap)
        for i: int in cap:
            slots[i] = Snapshot.new()


    ## Pushes a snapshot into the ring. Overwrites oldest if full.
    func push(snap: Snapshot) -> void:
        var writeIdx: int = (head + count) % capacity
        slots[writeIdx] = snap
        if count < capacity:
            count += 1
        else:
            head = (head + 1) % capacity


    ## Returns the i-th entry (0 = oldest, count-1 = newest).
    func get_at(i: int) -> Snapshot:
        return slots[(head + i) % capacity]


    ## Returns the newest entry.
    func newest() -> Snapshot:
        return slots[(head + count - 1) % capacity]


## Send position every Nth physics tick. 120 Hz / 6 = 20 Hz.
const SEND_EVERY_N_TICKS: int = 6
## Send vitals every Nth physics tick. 120 Hz / 240 = ~0.5 Hz (every 2s).
const VITALS_EVERY_N_TICKS: int = 240
## Interpolation delay in seconds. Two packets at 20 Hz covers jitter.
const INTERP_DELAY: float = 0.1

var sequenceNumber: int = 0
## Per-peer interpolation buffers. Maps peer_id -> [PeerBuffer].
## Dictionary is appropriate here: player count is dynamic (connect/disconnect).
var peerBuffers: Dictionary[int, PeerBuffer] = {}

# ---------- Broadcast ----------


## Called by the controller patch every physics tick. Throttles to 20 Hz before sending.
func broadcast_position(position: Vector3, rot: Vector3, flags: int) -> void:
    if !_cm.is_session_active():
        return

    if Engine.get_physics_frames() % SEND_EVERY_N_TICKS != 0:
        return
    sequenceNumber += 1

    receive_position.rpc(sequenceNumber, position, rot, flags)

# ---------- RPC Receive ----------


## Receives a remote player's position update. Sender is verified via
## [method MultiplayerAPI.get_remote_sender_id], not a caller-provided argument.
@rpc("any_peer", "call_remote", "unreliable")
func receive_position(seq: int, position: Vector3, rot: Vector3, flags: int) -> void:
    var peerId: int = multiplayer.get_remote_sender_id()
    var buf: PeerBuffer = null

    if peerId in peerBuffers:
        buf = peerBuffers[peerId]
        if seq <= buf.seq:
            return
    else:
        buf = PeerBuffer.new()
        peerBuffers[peerId] = buf

    buf.seq = seq
    buf.push(Snapshot.new(Time.get_ticks_msec() / 1000.0, position, rot, flags))

# ---------- Interpolation ----------


## Interpolates buffered snapshots for each remote peer and applies them to
## the corresponding [code]RemotePlayer[/code] node every physics tick.
func _physics_process(_delta: float) -> void:
    if !_cm.is_session_active():
        return

    var currentTime: float = Time.get_ticks_msec() / 1000.0
    var renderTime: float = currentTime - INTERP_DELAY
    var buf: PeerBuffer = null
    var remoteNode: Node3D = null
    var from: Snapshot = null
    var to: Snapshot = null
    var count: int = 0
    var timeDiff: float = 0.0
    var t: float = 0.0
    var snap: Snapshot = null

    for peerId: int in peerBuffers:
        buf = peerBuffers[peerId]
        count = buf.count
        remoteNode = _cm.get_remote_player_node(peerId)
        if remoteNode == null:
            continue

        if count < 2:
            if count == 1:
                snap = buf.get_at(0)
                remoteNode.update_state(snap.position, snap.rotation, snap.flags)
            continue

        # Find bracketing snapshots (oldest to newest via ring)
        from = buf.newest()
        to = from
        for i: int in range(1, count):
            if buf.get_at(i).timestamp >= renderTime:
                from = buf.get_at(i - 1)
                to = buf.get_at(i)
                break

        # No pruning — ring buffer overwrites oldest on push

        timeDiff = to.timestamp - from.timestamp
        t = 0.0
        if timeDiff > 0.0:
            t = clampf((renderTime - from.timestamp) / timeDiff, 0.0, 1.0)

        remoteNode.update_state(
            from.position.lerp(to.position, t),
            from.rotation.lerp(to.rotation, t),
            to.flags,
        )

# ---------- Utility ----------


## Broadcasts a footstep sound to all remote peers. Called by the controller patch.
## [param audioPath] is the resource path of the [AudioEvent] to play.
func broadcast_footstep(audioPath: String) -> void:
    if !_cm.is_session_active():
        return
    receive_footstep.rpc(audioPath)


## Receives a remote player's footstep event and plays it spatially.
@rpc("any_peer", "call_remote", "unreliable")
func receive_footstep(audioPath: String) -> void:
    var remoteNode: Node3D = _cm.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.play_remote_audio(audioPath)


## Broadcasts a weapon fire event to all remote peers. Called by the controller patch
## on the rising edge of [code]gameData.isFiring[/code].
## [param fireAudio] and [param tailAudio] are resource paths of [AudioEvent]s.
## [param showFlash] is false for suppressed weapons.
## [param hitPoint], [param hitNormal], [param hitSurface] describe the bullet impact.
func broadcast_fire_event(fireAudio: String, tailAudio: String, showFlash: bool, hitPoint: Vector3 = Vector3.ZERO, hitNormal: Vector3 = Vector3.ZERO, hitSurface: String = "") -> void:
    if !_cm.is_session_active():
        return
    receive_fire_event.rpc(fireAudio, tailAudio, showFlash, hitPoint, hitNormal, hitSurface)


## Receives a remote player's fire event — plays gunshot audio, muzzle flash, and bullet impact.
@rpc("any_peer", "call_remote", "unreliable")
func receive_fire_event(fireAudio: String, tailAudio: String, showFlash: bool, hitPoint: Vector3 = Vector3.ZERO, hitNormal: Vector3 = Vector3.ZERO, hitSurface: String = "") -> void:
    var remoteNode: Node3D = _cm.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.play_fire_event(fireAudio, tailAudio, showFlash)
    if hitPoint != Vector3.ZERO:
        remoteNode.spawn_bullet_impact(hitPoint, hitNormal, hitSurface)


## Broadcasts health to all remote peers. Called from [method _physics_process] at ~0.5 Hz.
func broadcast_vitals() -> void:
    if !_cm.is_session_active():
        return
    if Engine.get_physics_frames() % VITALS_EVERY_N_TICKS != 0:
        return
    var gd: GameData = preload("res://Resources/GameData.tres")
    receive_vitals.rpc(roundi(gd.health))


## Receives a remote player's health. Updates the remote player node for display.
@rpc("any_peer", "call_remote", "unreliable")
func receive_vitals(health: int) -> void:
    var remoteNode: Node3D = _cm.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.set_meta(&"health", health)


## Broadcasts a grenade throw to all remote peers. Called by grenade_rig_patch
## after ThrowHighExecute or ThrowLowExecute.
func broadcast_grenade_throw(grenadeScene: String, handleScene: String, throwPos: Vector3, throwRotY: float, throwDir: Vector3, basisX: Vector3, force: float) -> void:
    if !_cm.is_session_active():
        return
    receive_grenade_throw.rpc(grenadeScene, handleScene, throwPos, throwRotY, throwDir, basisX, force)


## Receives a remote player's grenade throw — instantiates grenade + handle with matching physics.
## The Grenade.gd fuse timer (3.0s) runs locally and detonates automatically.
@rpc("any_peer", "call_remote", "reliable")
func receive_grenade_throw(grenadeScene: String, handleScene: String, throwPos: Vector3, throwRotY: float, throwDir: Vector3, basisX: Vector3, force: float) -> void:
    # Validate resource paths (only allow grenade scenes from Items/)
    if !grenadeScene.begins_with("res://Items/Grenades/"):
        return

    var grenadePacked: PackedScene = load(grenadeScene) as PackedScene
    if grenadePacked == null:
        return

    var grenade: RigidBody3D = grenadePacked.instantiate() as RigidBody3D
    get_tree().root.add_child(grenade)
    grenade.position = throwPos
    grenade.rotation_degrees = Vector3(0, throwRotY, 0)
    grenade.linear_velocity = throwDir * force
    grenade.angular_velocity = basisX * 5.0

    if !handleScene.is_empty() && handleScene.begins_with("res://Items/Grenades/"):
        var handlePacked: PackedScene = load(handleScene) as PackedScene
        if handlePacked != null:
            var handleNode: RigidBody3D = handlePacked.instantiate() as RigidBody3D
            get_tree().root.add_child(handleNode)
            handleNode.position = throwPos
            handleNode.rotation_degrees = Vector3(0, throwRotY, 0)
            handleNode.linear_velocity = throwDir * force / 1.5
            handleNode.angular_velocity = -basisX * 5.0
            grenade.handle = handleNode


## Encodes [param data] movement booleans into a [enum MoveFlag] bitfield.
static func encode_flags(data: GameData) -> int:
    var flags: int = 0
    if data.isMoving:
        flags |= MoveFlag.MOVING
    if data.isWalking:
        flags |= MoveFlag.WALKING
    if data.isRunning:
        flags |= MoveFlag.RUNNING
    if data.isCrouching:
        flags |= MoveFlag.CROUCHING
    if data.isGrounded:
        flags |= MoveFlag.GROUNDED
    return flags


## Removes all buffered state for [param peerId].
func clear_peer(peerId: int) -> void:
    peerBuffers.erase(peerId)
