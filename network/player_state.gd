## Handles player position, rotation, and movement flag synchronisation over ENet.
## Owned by [code]CoopManager[/code] (added as a child node). All player-related RPCs live here.
extends Node

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


    func _init(t: float, p: Vector3, r: Vector3, f: int) -> void:
        timestamp = t
        position = p
        rotation = r
        flags = f


## Per-peer interpolation buffer. Holds sequence number and a ring of [Snapshot]s.
class PeerBuffer extends RefCounted:
    var seq: int = 0
    var states: Array[Snapshot] = []

## Send position every Nth physics tick. 120 Hz / 6 = 20 Hz.
const SEND_EVERY_N_TICKS: int = 6
## Interpolation delay in seconds. Two packets at 20 Hz covers jitter.
const INTERP_DELAY: float = 0.1
## Maximum buffered snapshots per peer before oldest is discarded.
const MAX_BUFFER_SIZE: int = 20

var sendTickCounter: int = 0
var sequenceNumber: int = 0
## Per-peer interpolation buffers. Maps peer_id -> [PeerBuffer].
var peerBuffers: Dictionary = { }
var cachedCoopManager: Node = null


func _ready() -> void:
    cachedCoopManager = get_parent()

# ---------- Broadcast ----------


## Called by the controller patch every physics tick. Throttles to 20 Hz before sending.
func BroadcastPosition(position: Vector3, rot: Vector3, flags: int) -> void:
    if !cachedCoopManager.isActive:
        return

    sendTickCounter += 1
    if sendTickCounter < SEND_EVERY_N_TICKS:
        return
    sendTickCounter = 0
    sequenceNumber += 1

    ReceivePosition.rpc(sequenceNumber, position, rot, flags)

# ---------- RPC Receive ----------


## Receives a remote player's position update. Sender is verified via
## [method MultiplayerAPI.get_remote_sender_id], not a caller-provided argument.
@rpc("any_peer", "call_remote", "unreliable")
func ReceivePosition(seq: int, position: Vector3, rot: Vector3, flags: int) -> void:
    var peerId: int = multiplayer.get_remote_sender_id()
    var buf: PeerBuffer

    if peerId in peerBuffers:
        buf = peerBuffers[peerId]
        if seq <= buf.seq:
            return
    else:
        buf = PeerBuffer.new()
        peerBuffers[peerId] = buf

    buf.seq = seq
    buf.states.append(Snapshot.new(Time.get_ticks_msec() / 1000.0, position, rot, flags))

    if buf.states.size() > MAX_BUFFER_SIZE:
        buf.states.pop_front()

# ---------- Interpolation ----------


## Interpolates buffered snapshots for each remote peer and applies them to
## the corresponding [code]RemotePlayer[/code] node every physics tick.
func _physics_process(_delta: float) -> void:
    if !cachedCoopManager.isActive:
        return

    var currentTime: float = Time.get_ticks_msec() / 1000.0
    var renderTime: float = currentTime - INTERP_DELAY

    for peerId: int in peerBuffers:
        var buf: PeerBuffer = peerBuffers[peerId]
        var states: Array[Snapshot] = buf.states
        var remoteNode: Node3D = cachedCoopManager.GetRemotePlayerNode(peerId)
        if remoteNode == null:
            continue

        if states.size() < 2:
            if states.size() == 1:
                var s: Snapshot = states[0]
                remoteNode.UpdateState(s.position, s.rotation, s.flags)
            continue

        var from: Snapshot
        var to: Snapshot
        var foundBracket: bool = false

        for i: int in range(1, states.size()):
            if states[i].timestamp >= renderTime:
                from = states[i - 1]
                to = states[i]
                foundBracket = true
                break

        # Hold latest position on packet loss instead of snapping to oldest.
        if !foundBracket:
            from = states[-1]
            to = from

        # Prune consumed snapshots but keep at least one before renderTime.
        while states.size() > 2 && states[1].timestamp < renderTime:
            states.pop_front()

        var timeDiff: float = to.timestamp - from.timestamp
        var t: float = 0.0
        if timeDiff > 0.0:
            t = clampf((renderTime - from.timestamp) / timeDiff, 0.0, 1.0)

        remoteNode.UpdateState(
            from.position.lerp(to.position, t),
            from.rotation.lerp(to.rotation, t),
            to.flags,
        )

# ---------- Utility ----------


## Encodes [param data] movement booleans into a [enum MoveFlag] bitfield.
static func EncodeFlags(data: Resource) -> int:
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
func ClearPeer(peerId: int) -> void:
    peerBuffers.erase(peerId)
