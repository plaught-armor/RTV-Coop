## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
extends Node

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager

## Sync simulation every 240 physics frames (~2s at 120Hz).
const SIM_SYNC_FRAMES: int = 240


func _physics_process(_delta: float) -> void:
    if !_cm.isActive || !_cm.isHost:
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
    # Broadcast to clients, then defer own transition so RPC flushes first
    sync_transition.rpc(transitionPath)
    transition.call_deferred("Interact")


## Host tells all clients to run a transition. Loads the scene directly
## via Loader to bypass the patched Interact (which would RPC back to host).
@rpc("authority", "call_remote", "reliable")
func sync_transition(transitionPath: String) -> void:
    if !is_valid_path(transitionPath):
        return
    var transition: Node = get_tree().current_scene.get_node_or_null(transitionPath)
    if transition == null:
        return
    # Read the destination from the transition node and load directly
    var nextMap: String = transition.get("nextMap")
    if nextMap == null || nextMap.is_empty():
        return
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
        return
    var pickup: Node = get_tree().current_scene.get_node_or_null(pickupPath)
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


## Host broadcasts a new pickup spawned in the world.
@rpc("authority", "call_remote", "reliable")
func sync_pickup_spawn(packedSlot: Dictionary, pos: Vector3, rot: Vector3, pickupName: String) -> void:
    var slotData: SlotData = _cm.SlotSerializerScript.unpack(packedSlot)
    if slotData == null:
        return
    # Find the PackedScene from Database using the item's file key
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        return
    var pickup: Node3D = scene.instantiate()
    pickup.name = pickupName
    pickup.slotData = slotData
    pickup.global_position = pos
    pickup.global_rotation = rot
    get_tree().current_scene.add_child(pickup)
    pickup.Freeze()


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

    # Sync simulation (reliable for initial join)
    sync_simulation_reliable.rpc_id(peerId, Simulation.time, Simulation.day, Simulation.weather)

# ---------- Validation ----------


## Validates a NodePath is safe (no traversal, no absolute paths).
func is_valid_path(nodePath: String) -> bool:
    return !nodePath.is_empty() && !(".." in nodePath) && !nodePath.begins_with("/")
