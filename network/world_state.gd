## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
class_name WorldState
extends Node

const SIM_SYNC_INTERVAL: float = 2.0
var simSyncTimer: float = 0.0


func _physics_process(delta: float) -> void:
    if !CoopManager.isActive || !CoopManager.isHost:
        return

    simSyncTimer += delta
    if simSyncTimer < SIM_SYNC_INTERVAL:
        return
    simSyncTimer = 0.0

    SyncSimulation.rpc(Simulation.time, Simulation.day, Simulation.weather)

# ---------- Door Sync ----------


## Client requests the host to interact with a door.
@rpc("any_peer", "call_remote", "reliable")
func RequestDoorInteract(doorPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(doorPath):
        return
    var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
    if !(door is Door):
        return
    door.Interact()


## Host broadcasts a door's state to peers. Clients animate accordingly.
@rpc("authority", "call_remote", "reliable")
func SyncDoorState(doorPath: String, isOpen: bool) -> void:
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
func SyncDoorUnlock(doorPath: String) -> void:
    var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
    if door == null || !(door is Door):
        return
    door.locked = false
    door.PlayUnlock()

# ---------- Switch Sync ----------


## Client requests the host to interact with a switch.
@rpc("any_peer", "call_remote", "reliable")
func RequestSwitchInteract(switchPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(switchPath):
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
    SyncSwitchState.rpc(switchPath, sw.active)


## Host broadcasts a switch state to peers.
@rpc("authority", "call_remote", "reliable")
func SyncSwitchState(switchPath: String, active: bool) -> void:
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
func RequestTransition(transitionPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(transitionPath):
        return
    var transition: Node = get_tree().current_scene.get_node_or_null(transitionPath)
    if transition == null || !transition.has_method("Interact"):
        return
    # Broadcast to clients, then defer own transition so RPC flushes first
    SyncTransition.rpc(transitionPath)
    transition.call_deferred("Interact")


## Host tells all clients to run a transition. Loads the scene directly
## via Loader to bypass the patched Interact (which would RPC back to host).
@rpc("authority", "call_remote", "reliable")
func SyncTransition(transitionPath: String) -> void:
    if !IsValidPath(transitionPath):
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
func SyncSpawnPosition(pos: Vector3) -> void:
    TeleportClient.rpc(pos)


## Teleports the client's local Controller to the given position.
@rpc("authority", "call_remote", "reliable")
func TeleportClient(pos: Vector3) -> void:
    var controller: Node3D = get_tree().current_scene.get_node_or_null("Core/Controller")
    if controller != null:
        controller.global_position = pos

# ---------- Container Sync ----------


## Client requests to open a loot container.
@rpc("any_peer", "call_remote", "reliable")
func RequestContainerOpen(containerPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(containerPath):
        return
    var container: Node = get_tree().current_scene.get_node_or_null(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.Interact()


## Host broadcasts a container's loot state to all peers.
@rpc("authority", "call_remote", "reliable")
func SyncContainerState(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = get_tree().current_scene.get_node_or_null(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = SlotSerializer.UnpackArray(packedLoot)


## Client requests to take a specific item from a container by index.
@rpc("any_peer", "call_remote", "reliable")
func RequestContainerTakeItem(containerPath: String, itemIndex: int) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(containerPath):
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
    GrantPickupToClient.rpc_id(requesterId, SlotSerializer.Pack(takenSlot))
    # Broadcast updated loot to all peers
    SyncContainerState.rpc(containerPath, SlotSerializer.PackArray(container.loot))

# ---------- Pickup Sync ----------


## Client requests to pick up an item. Host validates, marks consumed,
## sends the item data back to the requester, and broadcasts removal to all.
@rpc("any_peer", "call_remote", "reliable")
func RequestPickupInteract(pickupPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !IsValidPath(pickupPath):
        return
    var pickup: Node = get_tree().current_scene.get_node_or_null(pickupPath)
    if !is_instance_valid(pickup) || !(pickup is Pickup):
        return
    # Immediately mark consumed to prevent race condition (C2)
    pickup.remove_from_group(&"Item")
    # Send item data to the requesting client so they add it to their own inventory
    var requesterId: int = multiplayer.get_remote_sender_id()
    var packedSlot: Dictionary = SlotSerializer.Pack(pickup.slotData)
    GrantPickupToClient.rpc_id(requesterId, packedSlot)
    # Broadcast removal to all peers
    SyncPickupConsumed.rpc(pickupPath)
    pickup.queue_free()


## Host sends a pickup's item data to the client who picked it up.
## The client adds it to their own inventory locally.
@rpc("authority", "call_remote", "reliable")
func GrantPickupToClient(packedSlot: Dictionary) -> void:
    var slotData: SlotData = SlotSerializer.Unpack(packedSlot)
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
func SyncPickupConsumed(pickupPath: String) -> void:
    var pickup: Node = get_tree().current_scene.get_node_or_null(pickupPath)
    if is_instance_valid(pickup):
        pickup.queue_free()


## Host broadcasts a new pickup spawned in the world.
@rpc("authority", "call_remote", "reliable")
func SyncPickupSpawn(packedSlot: Dictionary, pos: Vector3, rot: Vector3, pickupName: String) -> void:
    var slotData: SlotData = SlotSerializer.Unpack(packedSlot)
    if slotData == null:
        return
    # Find the PackedScene from Database using the item's file key
    var scene: PackedScene = FindPickupScene(slotData.itemData.file)
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
func FindPickupScene(fileKey: String) -> PackedScene:
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
func SyncSimulation(syncTime: float, syncDay: int, syncWeather: String) -> void:
    Simulation.time = syncTime
    Simulation.day = syncDay
    Simulation.weather = syncWeather


## Reliable simulation sync for initial state on peer join.
@rpc("authority", "call_remote", "reliable")
func SyncSimulationReliable(syncTime: float, syncDay: int, syncWeather: String) -> void:
    Simulation.time = syncTime
    Simulation.day = syncDay
    Simulation.weather = syncWeather

# ---------- Full State Sync (on peer join) ----------


## Sends the current world state to a specific peer (called by host on peer connect).
func SendFullState(peerId: int) -> void:
    if !CoopManager.isHost:
        return

    # Sync all doors via Interactable group
    for node: Node in get_tree().get_nodes_in_group("Interactable"):
        var obj: Node = node.owner
        if obj is Door:
            var doorPath: String = get_tree().current_scene.get_path_to(obj)
            SyncDoorState.rpc_id(peerId, doorPath, obj.isOpen)
            if !obj.locked && obj.key:
                SyncDoorUnlock.rpc_id(peerId, doorPath)

    # Sync all switches
    for node: Node in get_tree().get_nodes_in_group("Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method("Activate"):
            continue
        var switchPath: String = get_tree().current_scene.get_path_to(obj)
        SyncSwitchState.rpc_id(peerId, switchPath, obj.active)

    # Sync simulation (reliable for initial join)
    SyncSimulationReliable.rpc_id(peerId, Simulation.time, Simulation.day, Simulation.weather)

# ---------- Validation ----------


## Validates a NodePath is safe (no traversal, no absolute paths).
func IsValidPath(nodePath: String) -> bool:
    return !nodePath.is_empty() && !(".." in nodePath) && !nodePath.begins_with("/")
