## Manages a headless SubViewport for a map where clients are present but the host
## is not. AI runs in the SubViewport's own physics world. A cloned GameData proxy
## isolates AI detection from the host's real GameData.
extends Node

## Emitted once the threaded scene load + finalize completes.
signal setup_finished(success: bool)

var _cm: Node
var mapPath: String = ""
var viewport: SubViewport = null
var mapScene: Node = null
var proxyGameData: Resource = null
var clientPeers: Array[int] = []
var syncedAI: Dictionary[int, Node] = {}
## Cached AISpawner + pool refs. Resolved in _finalize_setup, cleared in teardown.
var _aiSpawner: Node = null
var _aiAPool: Node = null
var _aiBPool: Node = null
var _aiAgents: Node = null
## Threaded-load state.
var _loadInProgress: bool = false
var _setupComplete: bool = false
var _setupCancelled: bool = false
## Per-peer slot array [pos, camPos, rot, flags] — reused to avoid per-tick alloc.
var clientPositions: Dictionary[int, Array] = {}
var savedSnapshot: Dictionary = {}
## AI centroid — invalidated once per physics frame.
var _centroidCache: Vector3 = Vector3.ZERO
var _centroidCacheFrame: int = -1

enum AIType { BANDIT, GUARD, MILITARY, PUNISHER }

## Packed door state bitmask for extract_door_states / restore.
enum DoorFlag { OPEN = 1, LOCKED = 2 }

## Patched scripts keyed by original resource path. Populated once per mod session.
## NOT thread-safe: assumes single-threaded Godot main loop. If off-thread access
## is ever introduced (e.g. WorkerThreadPool scanning), guard with a Mutex.
static var _patchMap: Dictionary = {}
static var _patchMapReady: bool = false

var _realGameData: Resource = preload("res://Resources/GameData.tres")


func init_manager(manager: Node) -> void:
    _cm = manager


## Kicks off threaded scene load. Caller must await [signal setup_finished].
func setup(path: String) -> bool:
    mapPath = path
    viewport = _make_headless_viewport(path)
    add_child(viewport)

    # CACHE_MODE_REUSE lets the threaded load coexist with vanilla
    # change_scene_to_file on the same path — REPLACE_DEEP fights over
    # cache locks and deadlocks when both target the same .scn/.tscn.
    # take_over_path already registered patched scripts system-wide, so
    # reuse picks them up. _reassign_patched_scripts handles edge cases.
    var err: int = ResourceLoader.load_threaded_request(
        path, "PackedScene", true, ResourceLoader.CACHE_MODE_REUSE
    )
    if err != OK:
        push_error("[HeadlessMap] Failed to queue threaded load (err %d): %s" % [err, path])
        return false
    _loadInProgress = true
    set_process(true)
    _log("Threaded load started for %s" % path)
    return true


## Polls threaded-load status; self-disables on completion.
func _process(_delta: float) -> void:
    if !_loadInProgress:
        set_process(false)
        return
    var status: int = ResourceLoader.load_threaded_get_status(mapPath)
    if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
        return
    _loadInProgress = false
    set_process(false)
    if status != ResourceLoader.THREAD_LOAD_LOADED:
        push_error("[HeadlessMap] Threaded load failed (status %d): %s" % [status, mapPath])
        setup_finished.emit(false)
        return
    _finalize_setup()


## Finalizes setup after the threaded load lands. instantiate() stays main-thread.
func _finalize_setup() -> void:
    if _setupCancelled || !is_instance_valid(viewport):
        return
    var scene: PackedScene = ResourceLoader.load_threaded_get(mapPath)
    if scene == null:
        push_error("[HeadlessMap] Failed to retrieve threaded scene: %s" % mapPath)
        setup_finished.emit(false)
        return
    mapScene = scene.instantiate()
    viewport.add_child(mapScene)

    # Headless doesn't need player/UI (Core) or sky/glow buffers (WorldEnvironment).
    var core: Node = mapScene.get_node_or_null("Core")
    if core != null:
        core.queue_free()
    _strip_world_environments(mapScene)

    # Belt-and-suspenders — CACHE_MODE_REPLACE_DEEP misses deeply nested refs.
    _reassign_patched_scripts(mapScene)

    _inject_proxy_gamedata()
    _cache_ai_spawner_refs()
    _inject_coop_manager()
    _setupComplete = true
    _log("SubViewport ready for %s" % mapPath)
    setup_finished.emit(true)


## Resolves AISpawner and its three pool children. Cleared in teardown.
func _cache_ai_spawner_refs() -> void:
    if mapScene == null:
        return
    _aiSpawner = mapScene.get_node_or_null("AI")
    if _aiSpawner == null:
        return
    _aiAPool = _aiSpawner.get_node_or_null("A_Pool")
    _aiBPool = _aiSpawner.get_node_or_null("B_Pool")
    _aiAgents = _aiSpawner.get_node_or_null("Agents")


## Builds a SubViewport with rendering/audio/buffers fully disabled.
## Settings applied BEFORE add_child() — Godot #102016 (own_world_3d after
## tree entry can crash).
func _make_headless_viewport(path: String) -> SubViewport:
    var vp: SubViewport = SubViewport.new()
    vp.name = "Headless_%s" % path.get_file().get_basename()
    vp.own_world_3d = true
    vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
    vp.physics_object_picking = false
    vp.gui_disable_input = true
    vp.process_mode = Node.PROCESS_MODE_DISABLED
    # Defensive buffer zeros — guard against future flips of update_mode.
    vp.audio_listener_enable_2d = false
    vp.audio_listener_enable_3d = false
    vp.msaa_2d = Viewport.MSAA_DISABLED
    vp.msaa_3d = Viewport.MSAA_DISABLED
    vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
    vp.use_taa = false
    vp.use_debanding = false
    vp.use_occlusion_culling = false
    vp.positional_shadow_atlas_size = 0
    vp.canvas_cull_mask = 0
    vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
    return vp


## Removes WorldEnvironment nodes — they allocate GPU buffers we never render.
func _strip_world_environments(root: Node) -> void:
    for child: Node in root.get_children():
        if child is WorldEnvironment:
            child.queue_free()
        else:
            _strip_world_environments(child)


## Broadcast rate pulled from ai_state so the two stay in lockstep.
const _AIStateScript: GDScript = preload("res://mod/network/ai_state.gd")


func start() -> void:
    if viewport == null:
        return
    viewport.process_mode = Node.PROCESS_MODE_INHERIT
    _register_ai_sync_ids.call_deferred()
    set_physics_process(true)
    _log("SubViewport started for %s" % mapPath)


## Broadcasts headless AI state to clients on this map at ~10Hz.
func _physics_process(_delta: float) -> void:
    if !_setupComplete || clientPeers.is_empty():
        return
    if Engine.get_physics_frames() % _AIStateScript.SEND_EVERY_N_TICKS != 0:
        return
    if !is_instance_valid(_aiAgents) || _aiAgents.get_child_count() == 0:
        return
    if !is_instance_valid(_cm) || _cm.aiState == null:
        return

    var batch: Array = _cm.aiState.pack_ai_batch(_aiAgents)
    if batch.is_empty():
        return

    # Send to each client on this map individually (not .rpc() which goes to all peers).
    for peerId: int in clientPeers:
        _cm.aiState.receive_ai_batch.rpc_id(
            peerId, batch[0], batch[1], batch[2], batch[3], batch[4], batch[5], batch[6], batch[7]
        )


## Reassigns patched scripts onto baked-in PackedScene references that
## take_over_path redirected after the scene was cached.
func _reassign_patched_scripts(root: Node) -> void:
    if !_patchMapReady:
        _init_patch_map()
    _walk_and_reassign(root)


## Populates _patchMap. Must run after CoopManager.register_patches().
static func _init_patch_map() -> void:
    if _patchMapReady:
        return
    var paths: PackedStringArray = [
        "res://Scripts/AI.gd", "res://Scripts/Door.gd", "res://Scripts/Switch.gd",
        "res://Scripts/Pickup.gd", "res://Scripts/LootContainer.gd",
        "res://Scripts/LootSimulation.gd", "res://Scripts/AISpawner.gd",
        "res://Scripts/Transition.gd", "res://Scripts/Fire.gd",
        "res://Scripts/Mine.gd", "res://Scripts/Explosion.gd",
        "res://Scripts/Trader.gd",
    ]
    for p: String in paths:
        var script: Script = load(p)
        if script != null:
            _patchMap[p] = script
    _patchMapReady = true


func _walk_and_reassign(node: Node) -> void:
    var script: Script = node.get_script()
    if script != null:
        var origPath: String = script.resource_path
        if origPath in _patchMap:
            var patched: Script = _patchMap[origPath]
            # Skip if already patched — avoids redundant work and state loss.
            if patched != null && script != patched:
                node.set_script(patched)
    for child: Node in node.get_children():
        _walk_and_reassign(child)


func _inject_proxy_gamedata() -> void:
    proxyGameData = _realGameData.duplicate()
    proxyGameData.isDead = false
    proxyGameData.isFlying = false
    proxyGameData.isCaching = false
    proxyGameData.isTrading = false
    _walk_and_inject(mapScene)


func _walk_and_inject(node: Node) -> void:
    if "gameData" in node:
        node.gameData = proxyGameData
    for child: Node in node.get_children():
        _walk_and_inject(child)


## Injects _cm reference into all patched nodes so RPC broadcasts work.
func _inject_coop_manager() -> void:
    if mapScene == null || _cm == null:
        return
    _walk_and_inject_cm(mapScene)


func _walk_and_inject_cm(node: Node) -> void:
    if "_cm" in node:
        node._cm = _cm
    for child: Node in node.get_children():
        _walk_and_inject_cm(child)


func _register_ai_sync_ids() -> void:
    if mapScene == null:
        return
    # Assign 0-based IDs matching ai_spawner_patch._assign_sync_ids order:
    # A_Pool children first, then B_Pool. Must match client's slot indexing.
    var idx: int = 0
    for holder: Node in [_aiAPool, _aiBPool]:
        if !is_instance_valid(holder):
            continue
        for child: Node in holder.get_children():
            child.set_meta(_M_AI_SYNC_ID, idx)
            child.set_meta(_M_AI_TYPE, _get_ai_type(child))
            child.tree_exiting.connect(_on_ai_tree_exiting.bind(idx))
            syncedAI[idx] = child
            idx += 1
    # Also tag any already-active agents (initial spawns reparented before this runs)
    if is_instance_valid(_aiAgents):
        for child: Node in _aiAgents.get_children():
            if child.has_meta(_M_AI_SYNC_ID):
                continue
            child.set_meta(_M_AI_SYNC_ID, idx)
            child.set_meta(_M_AI_TYPE, _get_ai_type(child))
            child.tree_exiting.connect(_on_ai_tree_exiting.bind(idx))
            syncedAI[idx] = child
            idx += 1
    _log("Registered %d AI sync IDs (0..%d)" % [idx, idx - 1])


func _on_ai_tree_exiting(syncId: int) -> void:
    syncedAI.erase(syncId)


## Every AI in the map — pools + active.
func _get_all_ai_nodes() -> Array[Node]:
    var result: Array[Node] = []
    for holder: Node in [_aiAPool, _aiBPool, _aiAgents]:
        if !is_instance_valid(holder):
            continue
        for ai: Node in holder.get_children():
            result.append(ai)
    return result


## Active (currently-spawned) AI only — the Agents child of the spawner.
## Active AI only (Agents child) — paused pool AI excluded.
func _get_active_ai_nodes() -> Array[Node]:
    if !is_instance_valid(_aiAgents):
        return []
    return _aiAgents.get_children()


## Index of the type char in [code]res://AI/<Type>/...[/code]. B/G/M/P → AIType.
const _AI_PATH_TYPE_IDX: int = 9


func _get_ai_type(node: Node) -> AIType:
    match node.scene_file_path[_AI_PATH_TYPE_IDX]:
        "G":
            return AIType.GUARD
        "M":
            return AIType.MILITARY
        "P":
            return AIType.PUNISHER
        _:
            return AIType.BANDIT

# ---------- Client Management ----------


func add_client(peerId: int) -> void:
    if peerId not in clientPeers:
        clientPeers.append(peerId)
        _log("Client %d added to headless %s" % [peerId, mapPath])


func remove_client(peerId: int) -> void:
    var idx: int = clientPeers.find(peerId)
    if idx >= 0:
        clientPeers.remove_at(idx)
    clientPositions.erase(peerId)
    _log("Client %d removed from headless %s" % [peerId, mapPath])

# ---------- Position Injection ----------


## Fixed slot indices for the reused clientPositions Array.
const _CP_POS: int = 0
const _CP_CAM: int = 1
const _CP_ROT: int = 2
const _CP_FLAGS: int = 3


func update_client_position(peerId: int, pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    if proxyGameData == null:
        return
    var slot: Array = clientPositions.get(peerId)
    if slot == null:
        slot = [pos, camPos, rot, flags]
        clientPositions[peerId] = slot
    else:
        slot[_CP_POS] = pos
        slot[_CP_CAM] = camPos
        slot[_CP_ROT] = rot
        slot[_CP_FLAGS] = flags

    if clientPositions.size() == 1:
        _apply_client_to_proxy(pos, camPos, rot, flags)
        return
    # Multiple clients: pick the one nearest the AI centroid.
    var centroid: Vector3 = _get_ai_centroid()
    var nearestDist: float = INF
    var nearest: Array
    for pid: int in clientPositions:
        var s: Array = clientPositions[pid]
        var dist: float = centroid.distance_squared_to(s[_CP_POS])
        if dist < nearestDist:
            nearestDist = dist
            nearest = s
    if nearest != null:
        _apply_client_to_proxy(nearest[_CP_POS], nearest[_CP_CAM], nearest[_CP_ROT], nearest[_CP_FLAGS])


func _apply_client_to_proxy(pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    proxyGameData.playerPosition = pos
    proxyGameData.cameraPosition = camPos
    proxyGameData.playerVector = -Vector3(sin(rot.y), 0, cos(rot.y))
    proxyGameData.isRunning = (flags & 4) != 0
    proxyGameData.isWalking = (flags & 2) != 0
    proxyGameData.isMoving = (flags & 1) != 0


## StringName constants for hot-path ai property lookups. StringName is a
## cached interned string; using String literals would re-intern every call.
const _P_DEAD: StringName = &"dead"
const _P_PAUSE: StringName = &"pause"
const _P_HEALTH: StringName = &"health"
const _P_CURRENT_STATE: StringName = &"currentState"
const _P_MOVEMENT_SPEED: StringName = &"movementSpeed"
const _P_MOVEMENT_ROTATION: StringName = &"movementRotation"
const _M_AI_SYNC_ID: StringName = &"ai_sync_id"
const _M_AI_TYPE: StringName = &"ai_type"
const _M_SPAWN_NOTIFIED: StringName = &"spawn_notified"


func _get_ai_centroid() -> Vector3:
    var frame: int = Engine.get_physics_frames()
    if frame == _centroidCacheFrame:
        return _centroidCache
    var sum: Vector3 = Vector3.ZERO
    var count: int = 0
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai):
            continue
        if ai.get(_P_DEAD) == true || ai.get(_P_PAUSE) == true:
            continue
        sum += ai.global_position
        count += 1
    _centroidCache = (sum / float(count)) if count > 0 else Vector3.ZERO
    _centroidCacheFrame = frame
    return _centroidCache

# ---------- AI State Extraction ----------


## Canonical per-AI state dict, shared by extract_ai_state + snapshot.
func _build_ai_state_dict(syncId: int, ai: Node) -> Dictionary:
    var curState: Variant = ai.get(_P_CURRENT_STATE)
    var speed: Variant = ai.get(_P_MOVEMENT_SPEED)
    var moveRot: Variant = ai.get(_P_MOVEMENT_ROTATION)
    var health: Variant = ai.get(_P_HEALTH)
    return {
        &"id": syncId,
        &"type": ai.get_meta(_M_AI_TYPE, 0),
        &"pos": ai.global_position,
        &"rot_y": ai.global_rotation.y,
        &"state": curState if curState != null else 0,
        &"speed": speed if speed != null else 0.0,
        &"move_rot": moveRot if moveRot != null else 0.0,
        &"health": health if health != null else 100,
        &"dead": ai.get(_P_DEAD) == true,
    }


func extract_ai_state() -> Array[Dictionary]:
    var states: Array[Dictionary] = []
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        # Guard against the gap between queue_free and tree_exiting firing.
        if !is_instance_valid(ai):
            continue
        if ai.get(_P_DEAD) == true || ai.get(_P_PAUSE) == true:
            continue
        states.append(_build_ai_state_dict(syncId, ai))
    return states


func get_new_spawns() -> Array[Dictionary]:
    var spawns: Array[Dictionary] = []
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai):
            continue
        if ai.has_meta(_M_SPAWN_NOTIFIED):
            continue
        ai.set_meta(_M_SPAWN_NOTIFIED, true)
        spawns.append({
            &"id": syncId,
            &"type": ai.get_meta(_M_AI_TYPE, 0),
            &"pos": ai.global_position,
        })
    return spawns

# ---------- World State ----------


func extract_door_states() -> Dictionary[NodePath, int]:
    var doors: Dictionary[NodePath, int] = {}
    if mapScene == null:
        return doors
    for node: Node in mapScene.get_tree().get_nodes_in_group(&"Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if !(obj is Door):
            continue
        if !mapScene.is_ancestor_of(obj):
            continue
        var door: Door = obj
        var flags: int = 0
        if door.isOpen:
            flags |= DoorFlag.OPEN
        if door.locked:
            flags |= DoorFlag.LOCKED
        doors[mapScene.get_path_to(door)] = flags
    return doors


func extract_switch_states() -> Dictionary[NodePath, bool]:
    var switches: Dictionary[NodePath, bool] = {}
    if mapScene == null:
        return switches
    for node: Node in mapScene.get_tree().get_nodes_in_group(&"Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method(&"Activate"):
            continue
        if !mapScene.is_ancestor_of(obj):
            continue
        switches[mapScene.get_path_to(obj)] = obj.get(&"active") == true
    return switches

# ---------- Snapshot / Restore ----------


func snapshot() -> Dictionary:
    var aiStates: Array[Dictionary] = []
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        # Snapshot keeps paused AI (they'll resume paused on restore); only
        # skip invalid or dead.
        if !is_instance_valid(ai) || ai.get(_P_DEAD) == true:
            continue
        aiStates.append(_build_ai_state_dict(syncId, ai))
    return {
        &"ai": aiStates,
        &"doors": extract_door_states(),
        &"switches": extract_switch_states(),
        &"items": extract_item_states(),
    }


## Captures items in the headless scene for transfer on handoff.
func extract_item_states() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if mapScene == null:
        return result
    for node: Node in mapScene.get_tree().get_nodes_in_group(&"Item"):
        if !is_instance_valid(node) || !mapScene.is_ancestor_of(node):
            continue
        if !(node is Node3D):
            continue
        var slotData: Resource = node.get(&"slotData")
        if slotData == null || slotData.itemData == null:
            continue
        result.append({
            &"file": slotData.itemData.file,
            &"pos": node.global_position,
            &"rot": node.global_rotation,
            &"slotData": slotData,
        })
    return result


## Yield cadence for restore passes — caps per-frame cost on large maps.
const _RESTORE_CHUNK: int = 64


## Async restore — doors/switches/AI each on their own frame, yielding every
## _RESTORE_CHUNK iterations within. Callers don't await (headless, invisible).
func restore(snap: Dictionary) -> void:
    if mapScene == null:
        return
    var doors: Dictionary = snap.get("doors", {})
    var switches: Dictionary = snap.get("switches", {})
    var aiSnaps: Array = snap.get("ai", [])

    await _restore_doors(doors)
    if !is_instance_valid(mapScene):
        return

    # Frame 2+: switches. Independent of doors (different node group, different
    # state), so no ordering dependency forces co-location.
    await get_tree().process_frame
    if !is_instance_valid(mapScene):
        return
    await _restore_switches(switches)
    if !is_instance_valid(mapScene):
        return

    # Frame 3+: AI. Heaviest pass — iterates the cached pool containers to
    # bucket by type. Last because it's the most expensive and also the least
    # visually important (AI in headless maps aren't being watched).
    if !aiSnaps.is_empty():
        await get_tree().process_frame
        if !is_instance_valid(mapScene):
            return
        var restored: int = await _restore_ai(aiSnaps)
        _log("Restored %d AI, %d doors, %d switches from snapshot" % [
            restored, doors.size(), switches.size()
        ])
    else:
        _log("Restored 0 AI, %d doors, %d switches from snapshot" % [
            doors.size(), switches.size()
        ])


func _restore_doors(doors: Dictionary) -> void:
    var i: int = 0
    for doorPath: NodePath in doors:
        var door: Node = mapScene.get_node_or_null(doorPath)
        if is_instance_valid(door) && door is Door:
            var flags: int = doors[doorPath]
            door.isOpen = (flags & DoorFlag.OPEN) != 0
            door.locked = (flags & DoorFlag.LOCKED) != 0
            if door.isOpen:
                door.animationTime = 4.0
        i += 1
        if i % _RESTORE_CHUNK == 0:
            await get_tree().process_frame
            if !is_instance_valid(mapScene):
                return


func _restore_switches(switches: Dictionary) -> void:
    var i: int = 0
    for switchPath: NodePath in switches:
        var sw: Node = mapScene.get_node_or_null(switchPath)
        if is_instance_valid(sw) && sw.has_method(&"Activate"):
            var active: bool = switches[switchPath]
            if active && !sw.active:
                sw.Activate()
            elif !active && sw.active:
                sw.Deactivate()
        i += 1
        if i % _RESTORE_CHUNK == 0:
            await get_tree().process_frame
            if !is_instance_valid(mapScene):
                return


## Bucket pool by AI type once — O(S+P) match via pop_back.
func _restore_ai(aiSnaps: Array) -> int:
    var poolByType: Dictionary = {}
    for ai: Node in _get_all_ai_nodes():
        var t: AIType = _get_ai_type(ai)
        if !poolByType.has(t):
            poolByType[t] = []
        poolByType[t].append(ai)
    var restored: int = 0
    var i: int = 0
    for aiSnap: Dictionary in aiSnaps:
        var bucket: Array = poolByType.get(aiSnap.get("type", 0), [])
        if !bucket.is_empty():
            var matched: Node = bucket.pop_back()
            matched.global_position = aiSnap.get("pos", Vector3.ZERO)
            matched.global_rotation.y = aiSnap.get("rot_y", 0.0)
            if "health" in matched:
                matched.health = aiSnap.get("health", 100)
            restored += 1
        i += 1
        if i % _RESTORE_CHUNK == 0:
            await get_tree().process_frame
            if !is_instance_valid(mapScene):
                return restored
    return restored


func teardown() -> void:
    # If the threaded load is still in flight we can't cancel it, but we can
    # flag finalize to skip its side effects so nothing gets re-added to a
    # freed viewport.
    _setupCancelled = true
    _loadInProgress = false
    set_process(false)
    set_physics_process(false)
    savedSnapshot = snapshot()
    if viewport != null:
        viewport.queue_free()
        viewport = null
    mapScene = null
    _aiSpawner = null
    _aiAPool = null
    _aiBPool = null
    _aiAgents = null
    syncedAI.clear()
    clientPositions.clear()
    _log("SubViewport torn down for %s" % mapPath)


func _log(msg: String) -> void:
    print("[HeadlessMap] %s" % msg)
