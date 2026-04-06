## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
extends Node

var _cm: Node

## Item sync: unique sync_id on each dropped item, signal-based detection.
var syncedItems: Dictionary = { } # sync_id -> Node (direct ref, cleared on tree_exiting)
var syncIdCounter: int = 0
var trackingItems: bool = false
var consumedSyncIDs: Array[String] = []
var droppedItemHistory: Array[Dictionary] = []
var mapNode: Node = null


func init_manager(manager: Node) -> void:
    _cm = manager


func start_item_tracking() -> void:
    if trackingItems:
        return
    trackingItems = true
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    syncIdCounter = 0
    # Connect to the map node's child_entered_tree to detect drops
    connect_map_signal()


func stop_item_tracking() -> void:
    disconnect_map_signal()
    trackingItems = false
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    syncIdCounter = 0


func connect_map_signal() -> void:
    disconnect_map_signal()
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    mapNode = scene
    mapNode.child_entered_tree.connect(on_map_child_entered)


func disconnect_map_signal() -> void:
    if is_instance_valid(mapNode) && mapNode.child_entered_tree.is_connected(on_map_child_entered):
        mapNode.child_entered_tree.disconnect(on_map_child_entered)
    mapNode = null


## Fires when a new direct child is added to the map scene root.
## Interface.Drop() adds pickups as direct children of /root/Map.
func on_map_child_entered(node: Node) -> void:
    if !trackingItems || !_cm.isActive:
        return
    if !(node is Pickup):
        return
    # Defer one frame so slotData is set by Interface.Drop()
    on_pickup_dropped.call_deferred(node.get_instance_id())


func on_pickup_dropped(instanceId: int) -> void:
    var node: Node = instance_from_id(instanceId)
    if !is_instance_valid(node) || !(node is Pickup):
        return
    # Skip items that already have a sync_id (received via RPC)
    if node.has_meta(&"sync_id"):
        return
    var slotData: SlotData = node.get("slotData")
    if slotData == null || slotData.itemData == null:
        return
    var packedSlot: Dictionary = _cm.SlotSerializerScript.pack(slotData)
    var pos: Vector3 = node.global_position if node.is_inside_tree() else Vector3.ZERO
    var rot: Vector3 = node.global_rotation if node.is_inside_tree() else Vector3.ZERO
    if _cm.isHost:
        register_synced_item(node, packedSlot, pos, rot)
    else:
        request_item_drop.rpc_id(1, packedSlot, pos, rot)


## Host assigns sync_id and broadcasts.
func register_synced_item(node: Node, packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    syncIdCounter += 1
    var syncId: String = "drop_%d" % syncIdCounter
    node.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = node
    node.tree_exiting.connect(on_synced_item_removed.bind(syncId))
    droppedItemHistory.append({ "id": syncId, "slot": packedSlot, "pos": pos, "rot": rot })
    sync_item_drop.rpc(syncId, packedSlot, pos, rot)


## Fires when a synced item is freed (picked up via original Interact).
func on_synced_item_removed(syncId: String) -> void:
    if syncId not in syncedItems:
        return
    syncedItems.erase(syncId)
    if !_cm.isActive:
        return
    if _cm.isHost:
        consumedSyncIDs.append(syncId)
        sync_item_consumed.rpc(syncId)
    else:
        request_item_consumed.rpc_id(1, syncId)


## Host broadcasts a dropped item to all clients.
@rpc("authority", "call_remote", "reliable")
func sync_item_drop(syncId: String, packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    var slotData: SlotData = _cm.SlotSerializerScript.unpack(packedSlot)
    if slotData == null:
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        return
    var pickup: Node3D = scene.instantiate()
    get_tree().current_scene.add_child(pickup)
    pickup.global_position = pos
    pickup.global_rotation = rot
    pickup.slotData.Update(slotData)
    if pickup.has_method("UpdateAttachments"):
        pickup.UpdateAttachments()
    if pickup.has_method("Unfreeze"):
        pickup.Unfreeze()
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup
    pickup.tree_exiting.connect(on_synced_item_removed.bind(syncId))


## Host broadcasts that a synced item was picked up — all peers remove it.
@rpc("authority", "call_remote", "reliable")
func sync_item_consumed(syncId: String) -> void:
    if syncId in syncedItems:
        var ref: WeakRef = syncedItems[syncId]
        var node: Node = ref.get_ref()
        if is_instance_valid(node):
            node.queue_free()
        syncedItems.erase(syncId)


## Client tells host an item was picked up locally.
@rpc("any_peer", "call_remote", "reliable")
func request_item_consumed(syncId: String) -> void:
    if !_cm.isHost:
        return
    if syncId in syncedItems:
        var ref: WeakRef = syncedItems[syncId]
        var node: Node = ref.get_ref()
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
    var slotData: SlotData = _cm.SlotSerializerScript.unpack(packedSlot)
    if slotData == null || slotData.itemData == null:
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        return
    syncIdCounter += 1
    var syncId: String = "drop_%d" % syncIdCounter
    var pickup: Node3D = scene.instantiate()
    get_tree().current_scene.add_child(pickup)
    pickup.global_position = pos
    pickup.global_rotation = rot
    pickup.slotData.Update(slotData)
    if pickup.has_method("UpdateAttachments"):
        pickup.UpdateAttachments()
    if pickup.has_method("Unfreeze"):
        pickup.Unfreeze()
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup
    pickup.tree_exiting.connect(on_synced_item_removed.bind(syncId))
    droppedItemHistory.append({ "id": syncId, "slot": packedSlot, "pos": pos, "rot": rot })
    # Broadcast to all EXCEPT the dropper
    var dropperId: int = multiplayer.get_remote_sender_id()
    for peerId: int in _cm.connectedPeers:
        if peerId != dropperId:
            sync_item_drop.rpc_id(peerId, syncId, packedSlot, pos, rot)

## Sync simulation every 240 physics frames (~2s at 120Hz).
const SIM_SYNC_FRAMES: int = 240


func _physics_process(_delta: float) -> void:
    if !_cm.isActive:
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
    var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
    if !(door is Door):
        return
    door.Interact()


## Host broadcasts a door's state to peers. Clients animate accordingly.
@rpc("authority", "call_remote", "reliable")
func sync_door_state(doorPath: String, isOpen: bool) -> void:
    var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
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
    var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
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
    var sw: Node = get_tree().current_scene.get_node_or_null(switchPath)
    if sw == null || !sw.has_method("Activate"):
        return
    sw.active = !sw.active
    if sw.active:
        sw.Activate()
        sw.PlaySwitch()
    else:
        sw.Deactivate()
        sw.PlaySwitch()
    sync_switch_state.rpc(switchPath, sw.active)


## Host broadcasts a switch state to peers.
@rpc("authority", "call_remote", "reliable")
func sync_switch_state(switchPath: String, active: bool) -> void:
    var sw: Node = get_tree().current_scene.get_node_or_null(switchPath)
    if sw == null:
        return
    if active && !sw.active:
        sw.Activate()
        sw.PlaySwitch()
    elif !active && sw.active:
        sw.Deactivate()
        sw.PlaySwitch()

# ---------- Transition Sync ----------


## Client requests the host to trigger a map transition.
@rpc("any_peer", "call_remote", "reliable")
func request_transition(transitionPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(transitionPath):
        return
    var transition: Node = get_tree().current_scene.get_node_or_null(transitionPath)
    if transition == null || !transition.has_method("Interact"):
        return
    # Broadcast to clients with current map name for spawn resolution
    var currentMapName: String = transition.get("currentMap") if transition.get("currentMap") != null else ""
    sync_transition.rpc(transitionPath, currentMapName)
    # Call super.Interact() directly via deferred to avoid going through the patch
    # (which would broadcast sync_transition a second time)
    var nextMap: String = transition.get("nextMap")
    if nextMap != null && !nextMap.is_empty():
        transition.call_deferred("host_transition_deferred")


## Host tells all clients to run a transition. Includes the current map name
## so clients can set previousMap for correct spawn point resolution in Compiler.Spawn().
@rpc("authority", "call_remote", "reliable")
func sync_transition(transitionPath: String, currentMapName: String = "") -> void:
    if !is_valid_path(transitionPath):
        return
    var transition: Node = get_tree().current_scene.get_node_or_null(transitionPath)
    if transition == null:
        return
    var nextMap: String = transition.get("nextMap")
    if nextMap == null || nextMap.is_empty():
        return
    # Set previousMap so Compiler.Spawn() finds the correct spawn point
    if !currentMapName.is_empty():
        _cm.gd.previousMap = currentMapName
        _cm.gd.currentMap = nextMap
    Loader.LoadScene(nextMap)


## Host sends spawn position to clients after a scene transition.
## Deferred so the host's Controller has had a frame to settle into its spawn point.
func sync_spawn_position(pos: Vector3) -> void:
    teleport_client.rpc(pos)


## Teleports the client's local Controller to the given position.
@rpc("authority", "call_remote", "reliable")
func teleport_client(pos: Vector3) -> void:
    var controller: Node3D = get_tree().current_scene.get_node_or_null("Core/Controller")
    if controller != null:
        controller.global_position = pos

# ---------- Container Sync ----------


## Client requests to open a loot container.
@rpc("any_peer", "call_remote", "reliable")
func request_container_open(containerPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(containerPath):
        return
    var container: Node = get_tree().current_scene.get_node_or_null(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.Interact()


## Host broadcasts a container's loot state to all peers.
@rpc("authority", "call_remote", "reliable")
func sync_container_state(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = get_tree().current_scene.get_node_or_null(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = _cm.SlotSerializerScript.unpack_array(packedLoot)


## Client requests to take a specific item from a container by index.
@rpc("any_peer", "call_remote", "reliable")
func request_container_take_item(containerPath: String, itemIndex: int) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(containerPath):
        return
    var container: Node = get_tree().current_scene.get_node_or_null(containerPath)
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
    grant_pickup_to_client.rpc_id(requesterId, _cm.SlotSerializerScript.pack(takenSlot))
    # Broadcast updated loot to all peers
    sync_container_state.rpc(containerPath, _cm.SlotSerializerScript.pack_array(container.loot))

# ---------- Pickup Sync ----------


## Client requests to pick up an item. Host validates, marks consumed,
## sends the item data back to the requester, and broadcasts removal to all.
@rpc("any_peer", "call_remote", "reliable")
func request_pickup_interact(pickupPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(pickupPath):
        print("[WorldState] request_pickup_interact: invalid path '%s'" % pickupPath)
        return
    var pickup: Node = get_tree().current_scene.get_node_or_null(pickupPath)
    print("[WorldState] request_pickup_interact: path='%s' found=%s" % [pickupPath, str(pickup != null)])
    if !is_instance_valid(pickup) || !(pickup is Pickup):
        return
    # Immediately mark consumed to prevent race condition (C2)
    pickup.remove_from_group(&"Item")
    # Send item data to the requesting client so they add it to their own inventory
    var requesterId: int = multiplayer.get_remote_sender_id()
    var packedSlot: Dictionary = _cm.SlotSerializerScript.pack(pickup.slotData)
    grant_pickup_to_client.rpc_id(requesterId, packedSlot)
    # Broadcast removal to all peers
    sync_pickup_consumed.rpc(pickupPath)
    pickup.queue_free()


## Host sends a pickup's item data to the client who picked it up.
## The client adds it to their own inventory locally.
@rpc("authority", "call_remote", "reliable")
func grant_pickup_to_client(packedSlot: Dictionary) -> void:
    var slotData: SlotData = _cm.SlotSerializerScript.unpack(packedSlot)
    if slotData == null:
        return
    var iface: Node = get_tree().current_scene.get_node_or_null("/root/Map/Core/UI/Interface")
    if iface == null:
        return
    if iface.AutoStack(slotData, iface.inventoryGrid):
        iface.UpdateStats(false)
    elif iface.Create(slotData, iface.inventoryGrid, false):
        iface.UpdateStats(false)


## Host broadcasts that a pickup was consumed (removed from world).
@rpc("authority", "call_remote", "reliable")
func sync_pickup_consumed(pickupPath: String) -> void:
    var pickup: Node = get_tree().current_scene.get_node_or_null(pickupPath)
    if is_instance_valid(pickup):
        pickup.queue_free()


## Looks up a Pickup PackedScene from the Database constants by item file key.
func find_pickup_scene(fileKey: String) -> PackedScene:
    var db: Node = get_node_or_null("/root/Database")
    if db == null:
        return null
    var constants: Dictionary = db.get_script().get_script_constant_map()
    if fileKey in constants:
        var res: Variant = constants[fileKey]
        if res is PackedScene:
            return res
    return null

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

# ---------- Full State Sync (on peer join) ----------


## Sends the current world state to a specific peer (called by host on peer connect).
func send_full_state(peerId: int) -> void:
    if !_cm.isHost:
        return

    # Sync all doors via Interactable group
    for node: Node in get_tree().get_nodes_in_group("Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if !(obj is Door):
            continue
        if !obj.has_method("Interact"):
            continue
        var doorPath: String = get_tree().current_scene.get_path_to(obj)
        var doorOpen: bool = obj.get("isOpen") if obj.get("isOpen") != null else false
        sync_door_state.rpc_id(peerId, doorPath, doorOpen)
        if !obj.locked && obj.get("key"):
            sync_door_unlock.rpc_id(peerId, doorPath)

    # Sync all switches
    for node: Node in get_tree().get_nodes_in_group("Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method("Activate"):
            continue
        var switchPath: String = get_tree().current_scene.get_path_to(obj)
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
