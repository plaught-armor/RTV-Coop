## Manages a headless SubViewport for a map where clients are present but the host
## is not. AI runs in the SubViewport's own physics world. A cloned GameData proxy
## isolates AI detection from the host's real GameData.
extends Node

## Emitted once the threaded scene load + finalize completes. Callers register
## with CONNECT_ONE_SHOT and apply snapshot restore / start() only after success.
signal setup_finished(success: bool)

var _cm: Node
var mapPath: String = ""
var viewport: SubViewport = null
var mapScene: Node = null
var proxyGameData: Resource = null
var clientPeers: Array[int] = []
var aiSyncIdCounter: int = 0
var syncedAI: Dictionary[int, Node] = {}
## Threaded-load state. While true, _process polls load_threaded_get_status each
## frame until LOADED/FAILED, then toggles itself off. Scene parse (20-40MB of
## meshes/deps) runs on a Godot worker thread; the blocking instantiate() call
## happens on the main thread but can't be avoided in Godot 4.x.
var _loadInProgress: bool = false
var _setupComplete: bool = false
var _setupCancelled: bool = false
## Per-peer position cache. Each value is a reused typed Array [pos, camPos, rot, flags]
## so we don't allocate a fresh Dictionary on every 20Hz position update.
var clientPositions: Dictionary[int, Array] = {}
var savedSnapshot: Dictionary = {}
## Cached AI centroid — invalidated once per physics frame. Avoids walking
## all syncedAI N times per frame when N clients all call update_client_position
## on the same tick (N*M → M work).
var _centroidCache: Vector3 = Vector3.ZERO
var _centroidCacheFrame: int = -1

enum AIType { BANDIT, GUARD, MILITARY, PUNISHER }

## Preloaded patched scripts keyed by original resource path. static so a single
## load happens per mod session instead of per-SubViewport setup. Populated
## lazily on first setup() after take_over_path has registered redirects.
static var _patchMap: Dictionary = {}
static var _patchMapReady: bool = false

var _realGameData: Resource = preload("res://Resources/GameData.tres")


func init_manager(manager: Node) -> void:
    _cm = manager


## Kicks off the threaded scene load. Returns true if the request was queued
## successfully — the actual scene is not ready until [signal setup_finished]
## fires. Callers must wait for that signal before calling [method start] or
## [method restore].
func setup(path: String) -> bool:
    mapPath = path
    viewport = _make_headless_viewport(path)
    add_child(viewport)

    # CACHE_MODE_REPLACE_DEEP forces dependency tree re-parse so ext_resources
    # (like AI.gd) resolve through take_over_path redirects. Without this, AI
    # prefabs cached before register_patches() keep their original script refs.
    var err: int = ResourceLoader.load_threaded_request(
        path, "PackedScene", true, ResourceLoader.CACHE_MODE_REPLACE_DEEP
    )
    if err != OK:
        push_error("[HeadlessMap] Failed to queue threaded load (err %d): %s" % [err, path])
        return false
    _loadInProgress = true
    set_process(true)
    _log("Threaded load started for %s" % path)
    return true


## Polls threaded-load status on the main thread. Self-disables once the load
## resolves. Cheap while active (one C++ atomic check + branch per frame);
## zero cost after completion.
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


## Runs after the threaded load completes. instantiate() still happens on the
## main thread (Godot 4.x constraint) but parse/deps/texture decode were done
## on a worker during the load phase.
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

    # Kill anything that doesn't belong in a headless simulation: the Core node
    # (player/UI) and any WorldEnvironment (sky/glow/SSAO/SSR buffers even with
    # UPDATE_DISABLED can hold GPU memory after environment assignment).
    var core: Node = mapScene.get_node_or_null("Core")
    if core != null:
        core.queue_free()
    _strip_world_environments(mapScene)

    # Belt-and-suspenders: reassign the patched script on every patched node class.
    # This handles cases where the PackedScene already baked in the original script
    # despite CACHE_MODE_REPLACE_DEEP (e.g., deeply nested instance references).
    _reassign_patched_scripts(mapScene)

    _inject_proxy_gamedata()
    _setupComplete = true
    _log("SubViewport ready for %s" % mapPath)
    setup_finished.emit(true)


## Builds a SubViewport configured for maximum "do as little as possible"
## mode — rendering is disabled, audio listeners off, all render buffers
## zeroed so nothing is allocated for MSAA/glow/TAA/shadow atlas/etc.
## Settings applied BEFORE add_child() to avoid Godot #102016 (own_world_3d
## toggle after tree entry can crash).
func _make_headless_viewport(path: String) -> SubViewport:
    var vp: SubViewport = SubViewport.new()
    vp.name = "Headless_%s" % path.get_file().get_basename()
    vp.own_world_3d = true
    vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
    vp.physics_object_picking = false
    vp.gui_disable_input = true
    vp.process_mode = Node.PROCESS_MODE_DISABLED
    # Defensive render-buffer zeros — these don't allocate when
    # UPDATE_DISABLED is set, but prevent regressions if a future code path
    # flips update_mode. All free, no downside.
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


## Removes any WorldEnvironment nodes from the scene. These allocate sky/glow/
## SSAO buffers on environment-assignment in some code paths, even though we
## never render — useless GPU memory in a headless simulation.
func _strip_world_environments(root: Node) -> void:
    for child: Node in root.get_children():
        if child is WorldEnvironment:
            child.queue_free()
        else:
            _strip_world_environments(child)


func start() -> void:
    if viewport == null:
        return
    viewport.process_mode = Node.PROCESS_MODE_INHERIT
    _register_ai_sync_ids.call_deferred()
    _log("SubViewport started for %s" % mapPath)


## Walks the newly-instantiated scene and force-reassigns patched scripts onto
## each matching node. Required because PackedScenes bake in Script references
## at load time — scenes cached before CoopManager.register_patches() still
## reference the original scripts even though take_over_path has redirected
## the paths. Resolving via load() picks up the redirect, then set_script
## replaces the baked-in reference.
func _reassign_patched_scripts(root: Node) -> void:
    if !_patchMapReady:
        _init_patch_map()
    _walk_and_reassign(root)


## Populates the shared static _patchMap. Called once per mod session.
## Must run AFTER CoopManager.register_patches() so load() resolves through
## take_over_path redirects to the patched scripts.
static func _init_patch_map() -> void:
    if _patchMapReady:
        return
    var paths: PackedStringArray = [
        "res://Scripts/AI.gd", "res://Scripts/Door.gd", "res://Scripts/Switch.gd",
        "res://Scripts/Pickup.gd", "res://Scripts/LootContainer.gd",
        "res://Scripts/LootSimulation.gd", "res://Scripts/AISpawner.gd",
        "res://Scripts/Transition.gd", "res://Scripts/Fire.gd",
        "res://Scripts/Mine.gd", "res://Scripts/Explosion.gd",
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
            # Only reassign if the currently-assigned script is not already the
            # patched version (avoids redundant work and potential state loss).
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


func _register_ai_sync_ids() -> void:
    if mapScene == null:
        return
    for node: Node in _get_all_ai_nodes():
        if node.has_meta(_M_AI_SYNC_ID):
            continue
        aiSyncIdCounter += 1
        node.set_meta(_M_AI_SYNC_ID, aiSyncIdCounter)
        node.set_meta(_M_AI_TYPE, _get_ai_type(node))
        # Self-cleaning registry: when the AI node leaves the tree (queue_free
        # from AISpawner, scene unload, etc.), the bound sync id gets erased
        # from syncedAI immediately. Avoids building a toErase list during
        # every extract_ai_state call to collect dead refs lazily.
        node.tree_exiting.connect(_on_ai_tree_exiting.bind(aiSyncIdCounter))
        syncedAI[aiSyncIdCounter] = node


func _on_ai_tree_exiting(syncId: int) -> void:
    syncedAI.erase(syncId)


func _get_all_ai_nodes() -> Array[Node]:
    var result: Array[Node] = []
    if mapScene == null:
        return result
    _collect_ai_recursive(mapScene, result)
    return result


func _collect_ai_recursive(node: Node, result: Array[Node]) -> void:
    if node is CharacterBody3D && node.has_method("Sensor"):
        result.append(node)
    for child: Node in node.get_children():
        _collect_ai_recursive(child, result)


## AI scene paths follow a fixed shape: [code]res://AI/<Type>/AI_<Type>.tscn[/code]
## where [code]<Type>[/code] is Bandit / Guard / Military / Punisher. The first
## character after the [code]res://AI/[/code] prefix (index 9) is therefore
## unique per type — B / G / M / P — so a single indexed char compare gives
## the enum value with no hashing or substring scan.
const _AI_PATH_TYPE_IDX: int = 9  # length of "res://AI/"


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


## Index slots inside the reused Array[Variant] held in clientPositions.
## Accessing by fixed int index avoids Dictionary string-key hashing that
## the old { "pos": ..., "camPos": ... } version paid on every 20Hz update.
const _CP_POS: int = 0
const _CP_CAM: int = 1
const _CP_ROT: int = 2
const _CP_FLAGS: int = 3


func update_client_position(peerId: int, pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    if proxyGameData == null:
        return
    # Reuse the slot array for this peer — no per-call Dictionary allocation.
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
    # Multiple clients: pick the one nearest the AI centroid. Centroid is the
    # running sum maintained elsewhere — no per-call tree walk.
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


## Builds the canonical per-AI state dict. Shared by [method extract_ai_state]
## (live sync to clients) and [method snapshot] (map teardown). Uses [code]&"key"[/code]
## StringName literals — interned at compile time. Consumers reading with plain
## [code]"key"[/code] Strings still match, because Godot 4 treats String and
## StringName as equivalent Dictionary keys.
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
        # is_instance_valid remains as a belt-and-suspenders guard — the
        # tree_exiting hook in _register_ai_sync_ids should have already
        # removed any freed AI, but nodes can be marked invalid between
        # queue_free() and the signal firing.
        if !is_instance_valid(ai):
            continue
        # Live sync: skip dead and paused — paused AI have no meaningful state
        # for clients to replicate, and dead AI are already removed via RPC.
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


func extract_door_states() -> Dictionary:
    var doors: Dictionary = {}
    if mapScene == null:
        return doors
    for node: Node in mapScene.get_tree().get_nodes_in_group("Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if !(obj is Door):
            continue
        if !mapScene.is_ancestor_of(obj):
            continue
        var doorPath: String = mapScene.get_path_to(obj)
        doors[doorPath] = {
            &"isOpen": obj.get(&"isOpen") if obj.get(&"isOpen") != null else false,
            &"locked": obj.get(&"locked") if obj.get(&"locked") != null else false,
        }
    return doors


func extract_switch_states() -> Dictionary:
    var switches: Dictionary = {}
    if mapScene == null:
        return switches
    for node: Node in mapScene.get_tree().get_nodes_in_group("Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method("Activate"):
            continue
        if !mapScene.is_ancestor_of(obj):
            continue
        var switchPath: String = mapScene.get_path_to(obj)
        switches[switchPath] = obj.get(&"active") if obj.get(&"active") != null else false
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


## Captures all items in the headless scene for transfer to the real scene.
## Each entry stores the item file path, position/rotation, and SlotData resource.
func extract_item_states() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if mapScene == null:
        return result
    for node: Node in mapScene.get_tree().get_nodes_in_group("Item"):
        if !is_instance_valid(node) || !mapScene.is_ancestor_of(node):
            continue
        if !(node is Node3D):
            continue
        var slotData: Resource = node.get("slotData")
        if slotData == null || slotData.itemData == null:
            continue
        result.append({
            &"file": slotData.itemData.file,
            &"pos": node.global_position,
            &"rot": node.global_rotation,
            &"slotData": slotData,
        })
    return result


func restore(snap: Dictionary) -> void:
    if mapScene == null:
        return
    var doors: Dictionary = snap.get("doors", {})
    for doorPath: String in doors:
        var door: Node = mapScene.get_node_or_null(doorPath)
        if !is_instance_valid(door) || !(door is Door):
            continue
        var state: Dictionary = doors[doorPath]
        door.isOpen = state.get("isOpen", false)
        door.locked = state.get("locked", false)
        if door.isOpen:
            door.animationTime = 4.0
    var switches: Dictionary = snap.get("switches", {})
    for switchPath: String in switches:
        var sw: Node = mapScene.get_node_or_null(switchPath)
        if !is_instance_valid(sw) || !sw.has_method("Activate"):
            continue
        var active: bool = switches[switchPath]
        if active && !sw.active:
            sw.Activate()
        elif !active && sw.active:
            sw.Deactivate()
    var aiSnaps: Array = snap.get("ai", [])
    if aiSnaps.is_empty():
        return
    # Bucket the pool by AI type once so each snapshot consumes a node in O(1)
    # via pop_back. Old version nested (aiSnaps × poolAI) with an `ai in
    # usedNodes` linear scan on top — effectively O(S² · P). New version is
    # O(S + P) and calls _get_ai_type once per pool entry instead of once per
    # (snapshot × candidate) pair.
    var poolByType: Dictionary = {}
    for ai: Node in _get_all_ai_nodes():
        var t: AIType = _get_ai_type(ai)
        if !poolByType.has(t):
            poolByType[t] = []
        poolByType[t].append(ai)
    var restored: int = 0
    for aiSnap: Dictionary in aiSnaps:
        var bucket: Array = poolByType.get(aiSnap.get("type", 0), [])
        if bucket.is_empty():
            continue
        var matched: Node = bucket.pop_back()
        matched.global_position = aiSnap.get("pos", Vector3.ZERO)
        matched.global_rotation.y = aiSnap.get("rot_y", 0.0)
        if "health" in matched:
            matched.health = aiSnap.get("health", 100)
        restored += 1
    _log("Restored %d AI, %d doors, %d switches from snapshot" % [
        restored, doors.size(), switches.size()
    ])


func teardown() -> void:
    # If the threaded load is still in flight we can't cancel it, but we can
    # flag finalize to skip its side effects so nothing gets re-added to a
    # freed viewport.
    _setupCancelled = true
    _loadInProgress = false
    set_process(false)
    savedSnapshot = snapshot()
    if viewport != null:
        viewport.queue_free()
        viewport = null
    mapScene = null
    syncedAI.clear()
    clientPositions.clear()
    _log("SubViewport torn down for %s" % mapPath)


func _log(msg: String) -> void:
    print("[HeadlessMap] %s" % msg)
