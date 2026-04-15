## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
extends Node

var _cm: Node
## Cached scene refs — repopulated from [method refresh_scene_cache] on every
## scene transition. Every RPC here previously started with
## [code]_scene_node(...)[/code]; that's a
## get_tree + current_scene property read + node lookup per RPC. With the
## cache it's one typed-var read + a node lookup. The UI manager and
## Interface are at well-known paths under each map's Core/UI subtree, so
## we pre-resolve those too and skip the redundant path walks in sync_container_open,
## grant_pickup_to_client, and apply_pickup_patch.
var _currentScene: Node = null
var _uiManager: Node = null
var _interface: Node = null
## Hoisted script refs cached from CoopManager after init_manager. Every RPC
## handler that packs/unpacks a slot used to chain [code]_slotSerializer[/code]
## (two property reads) on every call — 9 call sites across the file. Same
## for [code]_cm.PickupPatchScript[/code] in apply_pickup_patch.
var _slotSerializer: Script = null
var _pickupPatch: Script = null
## Lazy cache of Database.gd's script constants — item-file-key → PackedScene
## lookup. The game's Database autoload exposes all pickup scenes as [code]const[/code]
## members; the constant map is immutable, so resolve it once and reuse for
## every [method find_pickup_scene] call instead of re-reading via
## get_script().get_script_constant_map() on each drop.
var _dbConstants: Dictionary = {}
var _dbConstantsReady: bool = false


func init_manager(manager: Node) -> void:
    _cm = manager
    _slotSerializer = _slotSerializer
    _pickupPatch = _cm.PickupPatchScript


## Called from [method CoopManager.on_scene_changed] after every scene
## transition. current_scene is stable until the next transition, so we only
## need to resolve these once per map.
func refresh_scene_cache() -> void:
    _currentScene = get_tree().current_scene
    if !is_instance_valid(_currentScene):
        _uiManager = null
        _interface = null
        return
    _uiManager = _currentScene.get_node_or_null("Core/UI")
    _interface = _currentScene.get_node_or_null("Core/UI/Interface")


## Null-safe lookup against [member _currentScene]. Used by every RPC that
## would otherwise do [code]_scene_node(path)[/code] —
## if the scene cache hasn't been populated yet (RPC races a scene
## transition), this returns null and the caller's existing null check
## handles it.
func _scene_node(path: String) -> Node:
    if !is_instance_valid(_currentScene):
        return null
    return _currentScene.get_node_or_null(path)


## Item sync: unique sync_id on each dropped item.
## Drops are broadcast by interface_patch.Drop() calling broadcast_item_drop().
## Pickups are broadcast by pickup_patch.Interact() calling on_synced_item_picked_up().
var syncedItems: Dictionary = { }
var syncIdCounter: int = 0
var trackingItems: bool = false
var consumedSyncIDs: Array[String] = []
var droppedItemHistory: Array[Dictionary] = []
## Client-side queue of local pickups waiting for sync_id confirmation from host.
var pendingDrops: Array[Node] = []


func start_item_tracking() -> void:
    if trackingItems:
        return
    trackingItems = true
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    pendingDrops.clear()
    syncIdCounter = 0


func stop_item_tracking() -> void:
    trackingItems = false
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    pendingDrops.clear()
    syncIdCounter = 0


## Called by interface_patch.Drop() after each pickup is created locally.
func broadcast_item_drop(pickup: Node) -> void:
    if !trackingItems || !_cm.isActive:
        return
    var slotData: SlotData = pickup.get(&"slotData")
    if slotData == null || slotData.itemData == null:
        return
    var packedSlot: Dictionary = _slotSerializer.pack(slotData)
    var pos: Vector3 = pickup.global_position
    var rot: Vector3 = pickup.global_rotation
    if _cm.isHost:
        syncIdCounter += 1
        var syncId: String = "drop_%d" % syncIdCounter
        pickup.set_meta(&"sync_id", syncId)
        syncedItems[syncId] = pickup
        apply_pickup_patch(pickup)
        pickup._cm = _cm
        droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
        sync_item_drop.rpc(syncId, packedSlot, pos, rot)
    else:
        apply_pickup_patch(pickup)
        pickup._cm = _cm
        pendingDrops.append(pickup)
        request_item_drop.rpc_id(1, packedSlot, pos, rot)


## Called by pickup_patch.Interact() when a synced item is picked up.
func on_synced_item_picked_up(syncId: String) -> void:
    if !_cm.isHost:
        return
    syncedItems.erase(syncId)
    consumedSyncIDs.append(syncId)
    sync_item_consumed.rpc(syncId)


## Host broadcasts a dropped item to all clients.
@rpc("authority", "call_remote", "reliable")
func sync_item_drop(syncId: String, packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    var slotData: SlotData = _slotSerializer.unpack(packedSlot)
    if slotData == null:
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        return
    var pickup: Node3D = scene.instantiate()
    if !is_instance_valid(_currentScene):
        pickup.queue_free()
        return
    _currentScene.add_child(pickup)
    pickup.global_position = pos
    pickup.global_rotation = rot
    pickup.slotData.Update(slotData)
    if pickup.has_method(&"UpdateAttachments"):
        pickup.UpdateAttachments()
    # World items stay frozen at host's settled position; dropped items get physics
    if !syncId.begins_with("world_") && pickup.has_method(&"Unfreeze"):
        pickup.Unfreeze()
    # Swap to patched script, preserving exports
    apply_pickup_patch(pickup)
    pickup._cm = _cm
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup


## Host broadcasts that a synced item was picked up — all peers remove it.
@rpc("authority", "call_remote", "reliable")
func sync_item_consumed(syncId: String) -> void:
    if syncId in syncedItems:
        var node: Node = syncedItems[syncId]
        if is_instance_valid(node):
            node.queue_free()
        syncedItems.erase(syncId)


## Client tells host an item was picked up locally.
@rpc("any_peer", "call_remote", "reliable")
func request_item_consumed(syncId: String) -> void:
    if !_cm.isHost:
        return
    if syncId in syncedItems:
        var node: Node = syncedItems[syncId]
        if is_instance_valid(node):
            node.remove_from_group(&"Item")
            node.queue_free()
        syncedItems.erase(syncId)
        consumedSyncIDs.append(syncId)
        sync_item_consumed.rpc(syncId)


## Client requests host to register and broadcast a dropped item.
@rpc("any_peer", "call_remote", "reliable")
func request_item_drop(packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    if !_cm.isHost:
        return
    var dropperId: int = multiplayer.get_remote_sender_id()
    var slotData: SlotData = _slotSerializer.unpack(packedSlot)
    if slotData == null || slotData.itemData == null:
        reject_item_drop.rpc_id(dropperId)
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        reject_item_drop.rpc_id(dropperId)
        return
    syncIdCounter += 1
    var syncId: String = "drop_%d" % syncIdCounter
    var pickup: Node3D = scene.instantiate()
    if !is_instance_valid(_currentScene):
        pickup.queue_free()
        return
    _currentScene.add_child(pickup)
    pickup.global_position = pos
    pickup.global_rotation = rot
    pickup.slotData.Update(slotData)
    if pickup.has_method(&"UpdateAttachments"):
        pickup.UpdateAttachments()
    if pickup.has_method(&"Unfreeze"):
        pickup.Unfreeze()
    apply_pickup_patch(pickup)
    pickup._cm = _cm
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup
    droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
    # Broadcast to all EXCEPT the dropper
    for peerId: int in _cm.connectedPeers:
        if peerId != dropperId:
            sync_item_drop.rpc_id(peerId, syncId, packedSlot, pos, rot)
    # Confirm sync_id back to the dropper so their local pickup is tracked
    confirm_item_drop.rpc_id(dropperId, syncId)


## Host sends sync_id back to the client that dropped an item.
## The client tags their local pickup so future interact broadcasts removal.
@rpc("authority", "call_remote", "reliable")
func confirm_item_drop(syncId: String) -> void:
    if pendingDrops.is_empty():
        return
    var pickup: Node = pendingDrops.pop_front()
    if !is_instance_valid(pickup):
        return
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup


## Host tells the client that their drop request was rejected.
## The client pops the orphaned entry from pendingDrops to keep the FIFO aligned.
@rpc("authority", "call_remote", "reliable")
func reject_item_drop() -> void:
    if pendingDrops.is_empty():
        return
    pendingDrops.pop_front()

## Sync simulation every 240 physics frames (~2s at 120Hz).
const SIM_SYNC_FRAMES: int = 240


func _physics_process(_delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.isActive:
        return

    if !_cm.isHost:
        return

    if Engine.get_physics_frames() % SIM_SYNC_FRAMES != 0:
        return

    sync_simulation.rpc(Simulation.time, Simulation.day, Simulation.weather)

# ---------- Door Sync ----------


## Client requests the host to interact with a door.
@rpc("any_peer", "call_remote", "reliable")
func request_door_interact(doorPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(doorPath):
        return
    var door: Node = _scene_node(doorPath)
    if !(door is Door):
        return
    door.Interact()


## Host broadcasts a door's state to peers. Clients animate accordingly.
@rpc("authority", "call_remote", "reliable")
func sync_door_state(doorPath: String, isOpen: bool) -> void:
    var door: Node = _scene_node(doorPath)
    if door == null || !(door is Door):
        return
    door.isOpen = isOpen
    door.animationTime += 4.0
    door.handleMoving = true
    door.handleTarget = Vector3(0, 0, -45) if door.openAngle.y > 0.0 else Vector3(0, 0, 45)
    door.PlayDoor()


## Host broadcasts a door unlock to peers.
@rpc("authority", "call_remote", "reliable")
func sync_door_unlock(doorPath: String) -> void:
    var door: Node = _scene_node(doorPath)
    if door == null || !(door is Door):
        return
    door.locked = false
    door.PlayUnlock()

# ---------- Switch Sync ----------


## Client requests the host to interact with a switch.
@rpc("any_peer", "call_remote", "reliable")
func request_switch_interact(switchPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(switchPath):
        return
    var sw: Node = _scene_node(switchPath)
    if sw == null:
        return
    # Type-check: only process actual Switch nodes, not other Interactables
    if !sw.has_method(&"Activate") || !sw.has_method(&"PlaySwitch"):
        return
    # Use Interact() through the patch rather than manually toggling
    sw.Interact()


## Host broadcasts a switch state to peers.
@rpc("authority", "call_remote", "reliable")
func sync_switch_state(switchPath: String, active: bool) -> void:
    var sw: Node = _scene_node(switchPath)
    if sw == null:
        return
    if active && !sw.active:
        sw.Activate()
        sw.PlaySwitch()
    elif !active && sw.active:
        sw.Deactivate()
        sw.PlaySwitch()

# ---------- Container Sync ----------


## Client requests to open a loot container.
## Host packs the loot and sends it back — does NOT open its own UI.
@rpc("any_peer", "call_remote", "reliable")
func request_container_open(containerPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(containerPath):
        return
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    var packedLoot: Array[Dictionary] = _slotSerializer.pack_array(container.loot)
    var requesterId: int = multiplayer.get_remote_sender_id()
    sync_container_open.rpc_id(requesterId, containerPath, packedLoot)


## Host tells a specific client to open a container with the given loot.
## Sets the loot array first, then calls Interact() to open the UI locally.
@rpc("authority", "call_remote", "reliable")
func sync_container_open(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = _slotSerializer.unpack_array(packedLoot)
    # Open the container UI on this client
    if is_instance_valid(_uiManager) && _uiManager.has_method(&"OpenContainer"):
        _uiManager.OpenContainer(container)
        container.ContainerAudio()


## Host broadcasts a container's loot state to all peers (e.g., after item taken).
@rpc("authority", "call_remote", "reliable")
func sync_container_state(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = _slotSerializer.unpack_array(packedLoot)


## Client requests to take a specific item from a container by index.
@rpc("any_peer", "call_remote", "reliable")
func request_container_take_item(containerPath: String, itemIndex: int) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(containerPath):
        return
    var container: Node = _scene_node(containerPath)
    if !is_instance_valid(container) || !(container is LootContainer):
        return
    if itemIndex < 0 || itemIndex >= container.loot.size():
        return
    var takenSlot: SlotData = container.loot[itemIndex]
    if takenSlot == null:
        return
    # Remove from host's authoritative loot array
    container.loot.remove_at(itemIndex)
    # Send item to requesting client
    var requesterId: int = multiplayer.get_remote_sender_id()
    grant_pickup_to_client.rpc_id(requesterId, _slotSerializer.pack(takenSlot))
    # Broadcast updated loot to all peers
    sync_container_state.rpc(containerPath, _slotSerializer.pack_array(container.loot))

## Host sends an item to a specific client's inventory.
@rpc("authority", "call_remote", "reliable")
func grant_pickup_to_client(packedSlot: Dictionary) -> void:
    var slotData: SlotData = _slotSerializer.unpack(packedSlot)
    if slotData == null:
        return
    var iface: Node = _interface
    if !is_instance_valid(iface):
        return
    if iface.AutoStack(slotData, iface.inventoryGrid):
        iface.UpdateStats(false)
    elif iface.Create(slotData, iface.inventoryGrid, false):
        iface.UpdateStats(false)

# ---------- Pickup Sync ----------


## Looks up a Pickup PackedScene from the Database constants by item file key.
## Database is an autoload and its script constant map is immutable, so we
## resolve it lazily on first call and reuse the cached Dictionary for every
## subsequent lookup instead of walking the script reflection each time.
func find_pickup_scene(fileKey: String) -> PackedScene:
    if !_dbConstantsReady:
        var db: Node = get_node_or_null("/root/Database")
        if db == null:
            return null
        _dbConstants = db.get_script().get_script_constant_map()
        _dbConstantsReady = true
    if fileKey in _dbConstants:
        var res: Variant = _dbConstants[fileKey]
        if res is PackedScene:
            return res
    return null

## Registers all existing Item-group nodes in the current scene with sync_ids.
## Called by host after scene change. Broadcasts each item to connected clients
## and stores in droppedItemHistory for late joiners via send_full_state.
func register_scene_items() -> void:
    if !_cm.isHost || !trackingItems:
        return
    var itemCount: int = 0
    var skippedCount: int = 0
    for node: Node in get_tree().get_nodes_in_group(&"Item"):
        if node.has_meta(&"sync_id"):
            skippedCount += 1
            continue
        var slotData: SlotData = node.get(&"slotData")
        if slotData == null || slotData.itemData == null:
            skippedCount += 1
            continue
        itemCount += 1
        syncIdCounter += 1
        var syncId: String = "world_%d" % syncIdCounter
        node.set_meta(&"sync_id", syncId)
        syncedItems[syncId] = node
        apply_pickup_patch(node)
        node._cm = _cm
        var packedSlot: Dictionary = _slotSerializer.pack(slotData)
        var pos: Vector3 = node.global_position
        var rot: Vector3 = node.global_rotation
        droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
        sync_item_drop.rpc(syncId, packedSlot, pos, rot)
    _cm._log("register_scene_items: registered=%d skipped=%d total_in_group=%d" % [
        itemCount, skippedCount, itemCount + skippedCount])


## Swaps a Pickup node's script to the patched version, preserving exports.
func apply_pickup_patch(pickup: Node) -> void:
    var saved_slotData: SlotData = pickup.slotData
    var saved_mesh: MeshInstance3D = pickup.mesh
    var saved_collision: CollisionShape3D = pickup.collision
    pickup.set_script(_pickupPatch)
    pickup.slotData = saved_slotData
    pickup.mesh = saved_mesh
    pickup.collision = saved_collision
    pickup.interface = _interface

# ---------- Simulation Sync ----------


## Host periodically broadcasts time/day/weather to all peers (unreliable).
@rpc("authority", "call_remote", "unreliable")
func sync_simulation(syncTime: float, syncDay: int, syncWeather: String) -> void:
    Simulation.time = syncTime
    Simulation.day = syncDay
    Simulation.weather = syncWeather


## Reliable simulation sync for initial state on peer join.
@rpc("authority", "call_remote", "reliable")
func sync_simulation_reliable(syncTime: float, syncDay: int, syncWeather: String) -> void:
    Simulation.time = syncTime
    Simulation.day = syncDay
    Simulation.weather = syncWeather

# ---------- Fire Sync ----------


## Host broadcasts campfire state to all clients.
func broadcast_fire_state(firePath: String, isActive: bool) -> void:
    sync_fire_state.rpc(firePath, isActive)


## Client requests fire interaction from host.
@rpc("any_peer", "call_remote", "reliable")
func request_fire_interact(firePath: String) -> void:
    if !_cm.isHost:
        return
    var fire: Node = get_node_or_null(firePath)
    if !is_instance_valid(fire) || !fire.has_method(&"Interact"):
        return
    # Run the original interact on host (match check, activate/deactivate)
    fire.Interact()


## Client receives fire state from host.
@rpc("authority", "call_remote", "reliable")
func sync_fire_state(firePath: String, isActive: bool) -> void:
    var fire: Node = get_node_or_null(firePath)
    if !is_instance_valid(fire):
        return
    if isActive && !fire.active:
        fire.Activate()
        fire.active = true
    elif !isActive && fire.active:
        fire.Deactivate()
        fire.active = false

# ---------- Mine Sync ----------


## Host broadcasts mine detonation to all clients.
func broadcast_mine_detonate(minePath: String, instant: bool) -> void:
    receive_mine_detonate.rpc(minePath, instant)


## Client receives mine detonation event from host.
@rpc("authority", "call_remote", "reliable")
func receive_mine_detonate(minePath: String, instant: bool) -> void:
    var mine: Node = get_node_or_null(minePath)
    if !is_instance_valid(mine):
        return
    if instant:
        mine.InstantDetonate()
    else:
        mine.Detonate()

# ---------- Full State Sync (on peer join) ----------


## Sends the current world state to a specific peer (called by host on peer connect).
func send_full_state(peerId: int) -> void:
    if !_cm.isHost:
        return
    if !is_instance_valid(_currentScene):
        return
    # One local alias each for tree and scene — saves four property reads on
    # every iteration of the (Interactable + Switch) loops below.
    var tree: SceneTree = get_tree()
    var scene: Node = _currentScene

    # Sync all doors via Interactable group
    for node: Node in tree.get_nodes_in_group(&"Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if !(obj is Door):
            continue
        if !obj.has_method(&"Interact"):
            continue
        var doorPath: String = scene.get_path_to(obj)
        var doorOpen: bool = obj.get(&"isOpen") if obj.get(&"isOpen") != null else false
        sync_door_state.rpc_id(peerId, doorPath, doorOpen)
        if !obj.locked && obj.get(&"key"):
            sync_door_unlock.rpc_id(peerId, doorPath)

    # Sync all switches
    for node: Node in tree.get_nodes_in_group(&"Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method(&"Activate"):
            continue
        var switchPath: String = scene.get_path_to(obj)
        sync_switch_state.rpc_id(peerId, switchPath, obj.active)

    # Sync dropped items and consumed items for late joiners
    for item: Dictionary in droppedItemHistory:
        sync_item_drop.rpc_id(peerId, item["id"], item["slot"], item["pos"], item["rot"])
    for syncId: String in consumedSyncIDs:
        sync_item_consumed.rpc_id(peerId, syncId)

    # Sync simulation (reliable for initial join)
    sync_simulation_reliable.rpc_id(peerId, Simulation.time, Simulation.day, Simulation.weather)

# ---------- Validation ----------


## Validates a NodePath is safe (no traversal, no absolute paths).
func is_valid_path(nodePath: String) -> bool:
    return !nodePath.is_empty() && !(".." in nodePath) && !nodePath.begins_with("/")
