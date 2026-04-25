## Player position, rotation, and movement-flag sync over ENet.
extends Node



# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")

const RIG_MANAGER_PATH: NodePath = ^"Core/Camera/Manager"
const RIG_ATTACHMENTS: StringName = &"attachments"
const RIG_DATA: StringName = &"data"
const RIG_FILE: StringName = &"file"
const PATH_DATABASE: NodePath = ^"Database"

var _cachedRigManager: Node = null
var _cachedSceneId: int = 0



func _get_rig_manager() -> Node:
    var scene: Node = get_tree().current_scene
    if scene == null:
        _cachedRigManager = null
        _cachedSceneId = 0
        return null
    var sceneId: int = scene.get_instance_id()
    if _cachedSceneId != sceneId || !is_instance_valid(_cachedRigManager):
        _cachedRigManager = scene.get_node_or_null(RIG_MANAGER_PATH)
        _cachedSceneId = sceneId
    return _cachedRigManager



enum MoveFlag {
    MOVING = 1,
    WALKING = 2,
    RUNNING = 4,
    CROUCHING = 8,
    GROUNDED = 16,
    FLASHLIGHT = 32,
    # Mirrors isFiring continuously so AI FireDetection sees remotes like the host.
    FIRING = 64,
    # Mirrors isTrading so AI skips targeting remotes whose owner is in trade UI.
    TRADING = 128,
}


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


    func push_fields(timestamp: float, position: Vector3, rotation: Vector3, flags: int) -> void:
        var writeIdx: int = (head + count) % capacity
        var slot: Snapshot = slots[writeIdx]
        slot.timestamp = timestamp
        slot.position = position
        slot.rotation = rotation
        slot.flags = flags
        if count < capacity:
            count += 1
        else:
            head = (head + 1) % capacity


    func get_at(i: int) -> Snapshot:
        return slots[(head + i) % capacity]


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

## Last broadcast — used to skip the RPC when player hasn't moved or rotated.
## Resets on session start so the first broadcast always fires.
var _lastBroadcastPos: Vector3 = Vector3.INF
var _lastBroadcastRot: Vector3 = Vector3.INF
var _lastBroadcastFlags: int = -1
const POS_EPSILON: float = 0.005
const ROT_EPSILON: float = 0.001
## Force a broadcast at least every Nth gated tick so peers don't time out the
## interp buffer when a player stands still for many seconds.
const FORCE_KEEPALIVE_TICKS: int = 60
var _ticksSinceBroadcast: int = 0

## Last weapon name we broadcasted to peers. Used to rate-limit the equipment
## RPC to actual changes only — polling happens every [member EQUIPMENT_CHECK_TICKS]
## but the network path only fires when the value diverges.
var _lastBroadcastedWeapon: String = ""
## Last attachment-stem list we broadcasted. Tracked alongside
## [member _lastBroadcastedWeapon] so the attachment RPC only fires when the
## equipped weapon's nested optic/muzzle/laser actually changes. [StringName]
## because the source is [member WeaponRig.attachments]'s authored child
## [member Node.name] values — no need to round-trip through [String].
var _lastBroadcastedAttachments: Array[StringName] = []
## Poll interval for the equipment check. 120 Hz physics / 60 = 2 Hz — enough
## to catch weapon swaps with no perceptible delay; well under the bandwidth
## budget since the RPC is reliable + tiny.
const EQUIPMENT_CHECK_TICKS: int = 60



## Called by the controller patch every physics tick. Throttles to 20 Hz +
## skips the RPC when the local player hasn't moved/rotated/changed flags
## since the last send. Forces a keepalive every FORCE_KEEPALIVE_TICKS
## gated frames so a long-stationary player still refreshes the peer's
func broadcast_position(position: Vector3, rot: Vector3, flags: int) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return

    if Engine.get_physics_frames() % SEND_EVERY_N_TICKS != 0:
        return

    _ticksSinceBroadcast += 1
    var changed: bool = (
        flags != _lastBroadcastFlags
        || position.distance_squared_to(_lastBroadcastPos) > POS_EPSILON * POS_EPSILON
        || rot.distance_squared_to(_lastBroadcastRot) > ROT_EPSILON * ROT_EPSILON
    )
    if !changed && _ticksSinceBroadcast < FORCE_KEEPALIVE_TICKS:
        return

    _lastBroadcastPos = position
    _lastBroadcastRot = rot
    _lastBroadcastFlags = flags
    _ticksSinceBroadcast = 0
    sequenceNumber += 1

    receive_position.rpc(sequenceNumber, position, rot, flags)



## Receives a remote player's position update. Sender is verified via
## [method MultiplayerAPI.get_remote_sender_id], not a caller-provided argument.
@rpc("any_peer", "call_remote", "unreliable")
func receive_position(seq: int, position: Vector3, rot: Vector3, flags: int) -> void:
    var peerId: int = multiplayer.get_remote_sender_id()
    # If peer is on a different map, forward to headless map instead
    if !CoopManager.is_peer_on_same_map(peerId):
        if CoopManager.isHost:
            var camPos: Vector3 = position + Vector3(0, 1.6, 0)
            CoopManager.forward_position_to_headless(peerId, position, camPos, rot, flags)
        return
    var buf: PeerBuffer = null

    if peerId in peerBuffers:
        buf = peerBuffers[peerId]
        if seq <= buf.seq:
            return
    else:
        buf = PeerBuffer.new()
        peerBuffers[peerId] = buf

    buf.seq = seq
    buf.push_fields(Time.get_ticks_msec() / 1000.0, position, rot, flags)



## Interpolates buffered snapshots for each remote peer and applies them to
func _physics_process(_delta: float) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return

    if Engine.get_physics_frames() % EQUIPMENT_CHECK_TICKS == 0:
        _poll_equipment()

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
        remoteNode = CoopManager.get_remote_player_node(peerId)
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
            var candidate: Snapshot = buf.get_at(i)
            if candidate.timestamp >= renderTime:
                from = buf.get_at(i - 1)
                to = candidate
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



## Surface enum — index in this array is the int sent over the wire. Must
## stay stable across vmz versions or peers desync surface lookup. Append
## only; never reorder. Index 0 = Generic fallback for unknown surfaces.
const SURFACES: Array[String] = [
    "Generic", "Grass", "Dirt", "Asphalt", "Rock", "Wood",
    "Metal", "Concrete", "Snow", "Water", "Border", "Cables",
    "Target", "Flesh",
]


## Nested match on first char, then second only when first is ambiguous
func _surface_id(s: String) -> int:
    if s.is_empty():
        return 0
    match s[0]:
        "A": return 3   # Asphalt
        "B": return 10  # Border
        "D": return 2   # Dirt
        "F": return 13  # Flesh
        "M": return 6   # Metal
        "R": return 4   # Rock
        "S": return 8   # Snow
        "T": return 12  # Target
        "C":
            return 11 if s[1] == "a" else 7   # Cables vs Concrete
        "G":
            return 1 if s[1] == "r" else 0    # Grass vs Generic
        "W":
            return 9 if s[1] == "a" else 5    # Water vs Wood
    return 0


func _surface_name(id: int) -> String:
    if id < 0 || id >= SURFACES.size():
        return "Generic"
    return SURFACES[id]


## Audio path → int registry. Built once at module load by walking
## [AudioLibrary] + every weapon's fire/tail clips. Both peers preload the
## same source resources, so [member _audioPathById] is identical across
## peers and we can ship int IDs over the wire instead of res:// strings.
var _audioPathById: Dictionary[int, String] = {}
var _audioRegistryReady: bool = false


func _ensure_audio_registry() -> void:
    if _audioRegistryReady:
        return
    _audioRegistryReady = true
    var lib: Resource = load("res://Resources/AudioLibrary.tres") as Resource
    if lib != null:
        for prop: Dictionary in lib.get_property_list():
            var v: Variant = lib.get(prop.name)
            if v is Resource && v.resource_path != "":
                _audioPathById[v.resource_path.hash()] = v.resource_path
    var db: Node = Engine.get_main_loop().root.get_node_or_null(PATH_DATABASE) if Engine.get_main_loop() != null else null
    if db != null:
        for child: Node in db.get_children():
            for prop: Dictionary in child.get_property_list():
                var v: Variant = child.get(prop.name)
                if v is Resource && v.resource_path.begins_with("res://Resources/Audio"):
                    _audioPathById[v.resource_path.hash()] = v.resource_path


func _audio_id(path: String) -> int:
    if path.is_empty():
        return 0
    var h: int = path.hash()
    if !_audioPathById.has(h):
        _audioPathById[h] = path
    return h


func _audio_path(id: int) -> String:
    if id == 0:
        return ""
    _ensure_audio_registry()
    if _audioPathById.has(id):
        return _audioPathById[id]
    return ""


func broadcast_footstep(audioPath: String) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_footstep.rpc(_audio_id(audioPath))


@rpc("any_peer", "call_remote", "unreliable")
func receive_footstep(audioId: int) -> void:
    var remoteNode: Node3D = CoopManager.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    var path: String = _audio_path(audioId)
    if !path.is_empty():
        remoteNode.play_remote_audio(path)


func broadcast_fire_event(fireAudio: String, tailAudio: String, showFlash: bool, hitPoint: Vector3 = Vector3.ZERO, hitNormal: Vector3 = Vector3.ZERO, hitSurface: String = "") -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_fire_event.rpc(_audio_id(fireAudio), _audio_id(tailAudio), showFlash, hitPoint, hitNormal, _surface_id(hitSurface))


@rpc("any_peer", "call_remote", "unreliable")
func receive_fire_event(fireAudioId: int, tailAudioId: int, showFlash: bool, hitPoint: Vector3 = Vector3.ZERO, hitNormal: Vector3 = Vector3.ZERO, hitSurfaceId: int = 0) -> void:
    var remoteNode: Node3D = CoopManager.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.play_fire_event(_audio_path(fireAudioId), _audio_path(tailAudioId), showFlash)
    if hitPoint != Vector3.ZERO:
        remoteNode.spawn_bullet_impact(hitPoint, hitNormal, _surface_name(hitSurfaceId))


## Broadcasts health to all remote peers. Called from [method _physics_process] at ~0.5 Hz.
func broadcast_vitals() -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    if Engine.get_physics_frames() % VITALS_EVERY_N_TICKS != 0:
        return
    var gd: GameData = preload("res://Resources/GameData.tres")
    receive_vitals.rpc(roundi(gd.health))


@rpc("any_peer", "call_remote", "unreliable")
func receive_vitals(health: int) -> void:
    var remoteNode: Node3D = CoopManager.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.set_meta(&"health", health)


func broadcast_death() -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_death.rpc()


@rpc("any_peer", "call_remote", "reliable")
func receive_death() -> void:
    var peerId: int = multiplayer.get_remote_sender_id()
    CoopManager._log("[player_state] receive_death peer=%d" % peerId)
    var remoteNode: Node3D = CoopManager.get_remote_player_node(peerId)
    if remoteNode == null:
        CoopManager._log("[player_state] receive_death peer=%d NO_REMOTE" % peerId)
        return
    clear_peer(peerId)
    if remoteNode.has_method(&"die"):
        remoteNode.die()


## Broadcasts a knife attack audio event to all remote peers.
## [param isSlash]: true for slash, false for stab.
func broadcast_knife_attack(isSlash: bool, _attackId: int) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_knife_attack.rpc(isSlash)


@rpc("any_peer", "call_remote", "unreliable")
func receive_knife_attack(isSlash: bool) -> void:
    if !is_instance_valid(CoopManager):
        return
    var remoteNode: Node3D = CoopManager.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.play_knife_attack(isSlash)


func broadcast_knife_hit(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String, isFlesh: bool, attackId: int) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_knife_hit.rpc(hitPoint, hitNormal, _surface_id(hitSurface), isFlesh, attackId)


@rpc("any_peer", "call_remote", "unreliable")
func receive_knife_hit(hitPoint: Vector3, hitNormal: Vector3, hitSurfaceId: int, isFlesh: bool, attackId: int) -> void:
    if !is_instance_valid(CoopManager):
        return
    var remoteNode: Node3D = CoopManager.get_remote_player_node(multiplayer.get_remote_sender_id())
    if remoteNode == null:
        return
    remoteNode.spawn_knife_impact(hitPoint, hitNormal, _surface_name(hitSurfaceId), isFlesh, attackId)


func _is_valid_grenade_path(scenePath: String) -> bool:
    return scenePath.begins_with("res://Items/Grenades/") && !(".." in scenePath) && scenePath.ends_with(".tscn")


## Broadcasts a grenade throw to all remote peers. Called by grenade_rig_patch
func broadcast_grenade_throw(grenadeScene: String, handleScene: String, throwPos: Vector3, throwRotY: float, throwDir: Vector3, basisX: Vector3, force: float) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    if grenadeScene.is_empty():
        return
    receive_grenade_throw.rpc(grenadeScene, handleScene, throwPos, throwRotY, throwDir, basisX, force)


## Receives a remote player's grenade throw — instantiates grenade + handle with matching physics.
## The Grenade.gd fuse timer (3.0s) runs locally and detonates automatically.
## Paths are pre-validated by the sender in [method broadcast_grenade_throw].
@rpc("any_peer", "call_remote", "reliable")
func receive_grenade_throw(grenadeScene: String, handleScene: String, throwPos: Vector3, throwRotY: float, throwDir: Vector3, basisX: Vector3, force: float) -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    CoopManager._log("[player_state] receive_grenade_throw peer=%d scene=%s pos=%s force=%.2f" % [senderId, grenadeScene, str(throwPos), force])
    if !_is_valid_grenade_path(grenadeScene):
        CoopManager._log("[player_state] receive_grenade_throw REJECT_GRENADE_PATH=%s" % grenadeScene)
        return
    if !handleScene.is_empty() && !_is_valid_grenade_path(handleScene):
        CoopManager._log("[player_state] receive_grenade_throw REJECT_HANDLE_PATH=%s" % handleScene)
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

    if !handleScene.is_empty():
        var handlePacked: PackedScene = load(handleScene) as PackedScene
        if handlePacked != null:
            var handleNode: RigidBody3D = handlePacked.instantiate() as RigidBody3D
            get_tree().root.add_child(handleNode)
            handleNode.position = throwPos
            handleNode.rotation_degrees = Vector3(0, throwRotY, 0)
            handleNode.linear_velocity = throwDir * force / 1.5
            handleNode.angular_velocity = -basisX * 5.0
            grenade.handle = handleNode


## Broadcasts the local player's currently-held weapon name to every peer.
## [param weaponName] is the base-game file stem (e.g. [code]"AKM"[/code]);
## empty string means unarmed. Called from [method _physics_process] when the
func broadcast_equipment(weaponName: String) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_equipment.rpc(weaponName)


## Targeted variant used when a new peer spawns. Keeps the new peer in sync
func send_equipment_to(peerId: int, weaponName: String) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_equipment.rpc_id(peerId, weaponName)


## Receives another peer's equipment change. Weapon name is validated inside
## [method RemotePlayer.set_active_weapon] (allowlist regex); we only gate on
## length here before dispatching. Cached for spawn-order races.
@rpc("any_peer", "call_remote", "reliable")
func receive_equipment(weaponName: String) -> void:
    if !is_instance_valid(CoopManager):
        return
    if weaponName.length() > 32:
        CoopManager._log("[player_state] receive_equipment REJECT len=%d" % weaponName.length())
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    CoopManager._log("[player_state] receive_equipment peer=%d weapon=%s" % [peerId, weaponName])
    var remoteNode: Node3D = CoopManager.get_remote_player_node(peerId)
    if remoteNode == null:
        CoopManager._log("[player_state] receive_equipment peer=%d CACHE (no_remote)" % peerId)
        CoopManager.cache_peer_equipment(peerId, weaponName)
        return
    if remoteNode.has_method(&"set_active_weapon"):
        remoteNode.set_active_weapon(weaponName)


## Sends our chosen appearance to [param peerId]. Used by
## [code]coop_manager.spawn_remote_player[/code] so a newly-spawned peer can
func send_appearance_to(peerId: int, body: String, materialPath: String) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_appearance.rpc_id(peerId, body, materialPath)


## Receives another peer's appearance choice. Runs it through the allowlist in
## [appearance] before touching [RemotePlayer]. When the matching remote
## node hasn't spawned yet (sync_peer_map race) the entry is cached so
## [method coop_manager.spawn_remote_player] can apply it after instantiation.
@rpc("any_peer", "call_remote", "reliable")
func receive_appearance(body: String, materialPath: String) -> void:
    if !is_instance_valid(CoopManager):
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    var sanitized: Dictionary = CoopManager.appearance.sanitize({"body": body, "material": materialPath})
    CoopManager._log("[player_state] receive_appearance peer=%d body=%s material=%s" % [peerId, str(sanitized.body), str(sanitized.material)])
    CoopManager.apply_remote_appearance(peerId, sanitized)


func encode_flags(data: GameData) -> int:
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
    if data.flashlight:
        flags |= MoveFlag.FLASHLIGHT
    if data.isFiring:
        flags |= MoveFlag.FIRING
    if data.isTrading:
        flags |= MoveFlag.TRADING
    return flags


func clear_peer(peerId: int) -> void:
    peerBuffers.erase(peerId)


## Returns the weapon name last broadcast to peers, or the currently-drawn
## weapon if polling hasn't run yet. Used by [code]coop_manager[/code] when a
func get_current_weapon_name() -> String:
    if !_lastBroadcastedWeapon.is_empty():
        return _lastBroadcastedWeapon
    return _read_current_weapon_name()


## Polls the local player's current weapon name and broadcasts on change.
## Uses a stem like [code]"AKM"[/code] (matches the weapon's dir + pickup
## scene name under [code]res://Items/Weapons/[/code]); empty string = unarmed.
## No direct hook into [code]RigManager[/code] — checking its children each tick
func _poll_equipment() -> void:
    var current: String = _read_current_weapon_name()
    var weaponChanged: bool = current != _lastBroadcastedWeapon
    if weaponChanged:
        _lastBroadcastedWeapon = current
        broadcast_equipment(current)

    var attachments: Array[StringName] = _read_current_attachments()
    # Weapon-change forces a broadcast so remotes always get an authoritative
    # attachment list for the new weapon — otherwise an armed→armed swap with
    # matching (or both empty) attachment sets would leave stale visuals from
    # the previous weapon on the remote side.
    if weaponChanged || attachments != _lastBroadcastedAttachments:
        _lastBroadcastedAttachments = attachments
        broadcast_attachments(attachments)


## Reads currently-equipped attachment node names from the active [WeaponRig].
## Source is the rig's [member WeaponRig.attachments] child whose visible
## children are the ones [RigManager.UpdateRig] flipped on (Muzzle, Optic,
## Laser, and the Mount helper when [code]useMount && !optic.hasMount[/code]).
## Returns the [StringName]s directly so no [String] round-trip is needed on
## send, receive, or the per-peer [method RemotePlayer._apply_attachments]
func _read_current_attachments() -> Array[StringName]:
    var out: Array[StringName] = []
    var rigManager: Node = _get_rig_manager()
    if rigManager == null:
        return out
    for rig: Node in rigManager.get_children():
        var attachmentsNode: Node3D = rig.get(RIG_ATTACHMENTS) as Node3D
        if attachmentsNode == null:
            continue
        for child: Node in attachmentsNode.get_children():
            if child is Node3D && (child as Node3D).visible:
                out.append(child.name)
        break
    return out


## Broadcasts the current attachment [StringName]s to all peers. Empty list =
func broadcast_attachments(names: Array[StringName]) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_attachments.rpc(names)


## Targeted variant used when a new peer spawns. Mirrors [method send_equipment_to]
func send_attachments_to(peerId: int, names: Array[StringName]) -> void:
    if !is_instance_valid(CoopManager) || !CoopManager.is_session_active():
        return
    receive_attachments.rpc_id(peerId, names)


## Receives another peer's attachment change. No server authority check: the
## equipment RPC already gates visuals, and attachments don't affect damage on
## remote rigs (clients render host-authoritative hits). Cached for late-spawn.
@rpc("any_peer", "call_remote", "reliable")
func receive_attachments(names: Array[StringName]) -> void:
    if !is_instance_valid(CoopManager):
        return
    if names.size() > 16:
        push_warning("[player_state] Dropping attachment list from peer %d — size %d exceeds cap 16" % [multiplayer.get_remote_sender_id(), names.size()])
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    CoopManager._log("[player_state] receive_attachments peer=%d count=%d names=%s" % [peerId, names.size(), str(names)])
    var remoteNode: Node3D = CoopManager.get_remote_player_node(peerId)
    if remoteNode == null:
        CoopManager._log("[player_state] receive_attachments peer=%d CACHE (no_remote)" % peerId)
        CoopManager.cache_peer_attachments(peerId, names)
        return
    if remoteNode.has_method(&"set_active_attachments"):
        remoteNode.set_active_attachments(names)


## Returns the attachment list last broadcast to peers. Used by
## [code]coop_manager[/code] on new-peer spawn so the late-joiner sees our
func get_current_attachments() -> Array[StringName]:
    if !_lastBroadcastedAttachments.is_empty():
        return _lastBroadcastedAttachments
    return _read_current_attachments()


## Walks the local scene to find the active weapon name. Returns "" when no
func _read_current_weapon_name() -> String:
    var rigManager: Node = _get_rig_manager()
    if rigManager == null:
        return ""
    # Drawn weapons are added as RigManager children (see base RigManager.gd
    # DrawPrimary/DrawSecondary). WeaponRig exposes its data resource which
    # carries the file stem used across pickup/rig scene paths.
    for child: Node in rigManager.get_children():
        var data: Resource = child.get(RIG_DATA) as Resource
        if data == null:
            continue
        var fileName: Variant = data.get(RIG_FILE)
        if fileName is String && !(fileName as String).is_empty():
            return fileName
    return ""
