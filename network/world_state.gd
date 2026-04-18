## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
extends Node

var gameData: GameData = preload("res://Resources/GameData.tres")

var _cm: Node
## Cached scene refs, refreshed per scene transition.
var _currentScene: Node = null
var _uiManager: Node = null
var _interface: Node = null
## Hoisted from CoopManager in init_manager.
var _slotSerializer: Script = null
var _pickupPatch: Script = null
## Database script-constant map — resolved lazily on first pickup lookup.
var _dbConstants: Dictionary = {}
var _dbConstantsReady: bool = false
## Event history for late-joiner replay. Each entry: [eventName, params].
var _firedEvents: Array = []


func init_manager(manager: Node) -> void:
    _cm = manager
    _slotSerializer = _cm.SlotSerializerScript
    _pickupPatch = _cm.PickupPatchScript


## Called from [method CoopManager.on_scene_changed].
func refresh_scene_cache() -> void:
    _currentScene = get_tree().current_scene
    _firedEvents.clear()
    if !is_instance_valid(_currentScene):
        _uiManager = null
        _interface = null
        return
    _uiManager = _currentScene.get_node_or_null("Core/UI")
    _interface = _currentScene.get_node_or_null("Core/UI/Interface")


## Null-safe lookup against [member _currentScene].
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


## Host runs Interact on a door locally and broadcasts the resulting state.
## Used by both host's local Interactor patch and by request_door_interact (client path).
func host_door_interact(door: Node) -> void:
    if !_cm.isHost || !is_instance_valid(door) || !(door is Door) || !is_instance_valid(_currentScene):
        return
    var doorPath: String = _currentScene.get_path_to(door)
    var wasLocked: bool = door.locked
    door.Interact()
    sync_door_state.rpc(doorPath, door.isOpen)
    if wasLocked && !door.locked:
        sync_door_unlock.rpc(doorPath)
        if is_instance_valid(door.linked):
            var linkedPath: String = _currentScene.get_path_to(door.linked)
            sync_door_unlock.rpc(linkedPath)
    if _cm.DEBUG:
        print("[world_state] host_door_interact %s isOpen=%s" % [doorPath, door.isOpen])


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
    host_door_interact(door)


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


## Host runs Interact on a switch locally and broadcasts the resulting state.
func host_switch_interact(sw: Node) -> void:
    if !_cm.isHost || !is_instance_valid(sw) || !is_instance_valid(_currentScene):
        return
    if !sw.has_method(&"Activate") || !sw.has_method(&"PlaySwitch"):
        return
    var switchPath: String = _currentScene.get_path_to(sw)
    sw.Interact()
    sync_switch_state.rpc(switchPath, sw.active)
    if _cm.DEBUG:
        print("[world_state] host_switch_interact %s active=%s" % [switchPath, sw.active])


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
    host_switch_interact(sw)


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

# ---------- Bed Sync ----------


## Host triggers sleep: runs the bed locally (advances Simulation, adjusts its
## own vitals, plays transition audio) and broadcasts the duration so clients
## freeze + play audio in lock-step. Clients also apply matching stat deltas
## so everyone wakes with the same energy/hydration/mental state.
func host_bed_interact(bed: Node) -> void:
    if !_cm.isHost || !is_instance_valid(bed) || !is_instance_valid(_currentScene):
        return
    if !bed.has_method(&"Interact") || !bed.canSleep:
        return
    var duration: int = int(bed.randomSleep)
    var bedPath: String = _currentScene.get_path_to(bed)
    sync_bed_sleep.rpc(bedPath, duration)
    bed.Interact()


## Client asks the host to sleep on a specific bed.
@rpc("any_peer", "call_remote", "reliable")
func request_bed_interact(bedPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(bedPath):
        return
    var bed: Node = _scene_node(bedPath)
    if !is_instance_valid(bed):
        return
    host_bed_interact(bed)


## Host broadcasts the sleep fire + duration so clients freeze locally and
## play the transition/sleep audio. Simulation time advances from the host's
## own Bed.Interact() via the normal sync_simulation broadcast.
@rpc("authority", "call_remote", "reliable")
func sync_bed_sleep(bedPath: String, duration: int) -> void:
    var bed: Node = _scene_node(bedPath)
    if !is_instance_valid(bed):
        return
    gameData.isSleeping = true
    gameData.freeze = true
    if bed.has_method(&"PlayTransition"):
        bed.PlayTransition()
    if bed.has_method(&"PlaySleep"):
        bed.PlaySleep()
    await get_tree().create_timer(float(duration), false).timeout
    if !is_instance_valid(self):
        return
    gameData.energy -= 20.0
    gameData.hydration -= 20.0
    gameData.mental += 20.0
    gameData.isSleeping = false
    gameData.freeze = false
    Loader.Message("You slept " + str(duration) + " hours", Color.GREEN)


# ---------- Container Sync ----------


## Host opens a container locally and broadcasts its current loot state.
func host_container_interact(container: Node) -> void:
    if !_cm.isHost || !is_instance_valid(container) || !(container is LootContainer) || !is_instance_valid(_currentScene):
        return
    var containerPath: String = _currentScene.get_path_to(container)
    container.Interact()
    var packedLoot: Array[Dictionary] = _slotSerializer.pack_array(container.loot)
    sync_container_state.rpc(containerPath, packedLoot)
    if _cm.DEBUG:
        print("[world_state] host_container_interact %s loot=%d" % [containerPath, container.loot.size()])


## Host opens a trader locally. No broadcast — trader UI is per-client.
func host_trader_interact(trader: Node) -> void:
    if !_cm.isHost || !is_instance_valid(trader) || !trader.has_method(&"Interact"):
        return
    trader.Interact()
    if _cm.DEBUG:
        print("[world_state] host_trader_interact %s" % trader.name)


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


## Looks up a Pickup PackedScene from Database constants by file key.
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

# ---------- Trader Sync ----------


## Client requests to open a trader. Host sends current supply back.
@rpc("any_peer", "call_remote", "reliable")
func request_trader_open(traderPath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(traderPath):
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader) || !trader.has_method(&"Interact"):
        return
    var packedSupply: Array[Dictionary] = _slotSerializer.pack_array(trader.supply)
    var tax: int = int(trader.tax)
    var requesterId: int = multiplayer.get_remote_sender_id()
    sync_trader_supply.rpc_id(requesterId, traderPath, packedSupply, tax)


## Host sends trader supply to a specific client. Client opens the trader UI.
@rpc("authority", "call_remote", "reliable")
func sync_trader_supply(traderPath: String, packedSupply: Array[Dictionary], tax: int) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    # Replace local supply with host's authoritative copy.
    trader.supply = _slotSerializer.unpack_array(packedSupply)
    trader.tax = tax
    var uiMgr: Node = _scene_node("Core/UI")
    if is_instance_valid(uiMgr) && uiMgr.has_method(&"OpenTrader"):
        uiMgr.OpenTrader(trader)


## Client requests a trade. Sends indices of supply items wanted + packed offered items.
@rpc("any_peer", "call_remote", "reliable")
func request_trade(traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(traderPath):
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    var requesterId: int = multiplayer.get_remote_sender_id()

    # Validate requested indices still exist.
    var requestedItems: Array[SlotData] = []
    for idx: int in requestedIndices:
        if idx < 0 || idx >= trader.supply.size():
            reject_trade.rpc_id(requesterId)
            return
        var slot: SlotData = trader.supply[idx]
        if slot == null || slot.itemData == null:
            reject_trade.rpc_id(requesterId)
            return
        requestedItems.append(slot)

    # Validate offered value covers request + tax.
    var offeredItems: Array[SlotData] = _slotSerializer.unpack_array(offeredSlots)
    var requestValue: float = 0.0
    for slot: SlotData in requestedItems:
        requestValue += slot.Value() * (trader.tax * 0.01 + 1.0)
    var offerValue: float = 0.0
    for slot: SlotData in offeredItems:
        if slot != null:
            offerValue += slot.Value()
    if offerValue < requestValue:
        reject_trade.rpc_id(requesterId)
        return

    # Execute: remove from supply (reverse order to keep indices valid).
    var sortedIndices: PackedInt32Array = requestedIndices.duplicate()
    sortedIndices.sort()
    for i: int in range(sortedIndices.size() - 1, -1, -1):
        trader.supply.remove_at(sortedIndices[i])

    # Grant items to client.
    var grantedSlots: Array[Dictionary] = _slotSerializer.pack_array(requestedItems)
    sync_trade_granted.rpc_id(requesterId, grantedSlots)

    # Broadcast updated supply to all peers.
    var packedSupply: Array[Dictionary] = _slotSerializer.pack_array(trader.supply)
    sync_trader_supply_update.rpc(traderPath, packedSupply)


## Host tells client their trade was rejected. Restores hidden offered items.
@rpc("authority", "call_remote", "reliable")
func reject_trade() -> void:
    _cm._log("[Trader] Trade rejected by host")
    var pending: Array = get_meta(&"_pending_trade_elements", [])
    for element: Node in pending:
        if is_instance_valid(element):
            element.visible = true
            element.remove_meta(&"trade_pending")
    remove_meta(&"_pending_trade_elements")


## Host grants purchased items to the requesting client.
## Finalizes the trade: removes pending offered items and spawns granted items.
@rpc("authority", "call_remote", "reliable")
func sync_trade_granted(grantedSlots: Array[Dictionary]) -> void:
    # Remove offered items that were hidden pending ACK.
    var pending: Array = get_meta(&"_pending_trade_elements", [])
    var iface: Node = _interface
    if is_instance_valid(iface):
        for element: Node in pending:
            if is_instance_valid(element):
                iface.inventoryGrid.Pick(element)
                element.queue_free()
    remove_meta(&"_pending_trade_elements")

    if !is_instance_valid(iface):
        return
    for packed: Dictionary in grantedSlots:
        var slot: SlotData = _slotSerializer.unpack(packed)
        if slot == null:
            continue
        if slot.itemData.type == "Furniture":
            iface.Create(slot, iface.catalogGrid, false)
        else:
            iface.Create(slot, iface.inventoryGrid, true)
    iface.UpdateStats(false)


## Host broadcasts updated supply after a trade. All clients refresh if viewing.
@rpc("authority", "call_remote", "reliable")
func sync_trader_supply_update(traderPath: String, packedSupply: Array[Dictionary]) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    trader.supply = _slotSerializer.unpack_array(packedSupply)
    # Refresh the supply grid if this trader is currently open.
    var iface: Node = _interface
    if is_instance_valid(iface) && is_instance_valid(iface.trader) && iface.trader == trader:
        if iface.has_method(&"Resupply"):
            iface.Resupply()


## Client asks host to mark a task as completed. Host applies locally
## (including the Traders.tres save — host is authoritative for disk) and
## broadcasts to every peer. Matches [method Trader.CompleteTask] side
## effects across the session so no one double-completes.
@rpc("any_peer", "call_remote", "reliable")
func request_trader_task_complete(traderPath: String, taskName: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(traderPath):
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    if trader.tasksCompleted.has(taskName):
        return
    # Host applies + saves the same as solo. No TaskData object in hand, so we
    # inline the parts of Trader.CompleteTask that don't need one.
    trader.tasksCompleted.append(taskName)
    if trader.has_method(&"PlayTraderTask"):
        trader.PlayTraderTask()
    if !gameData.tutorial:
        Loader.SaveTrader(trader.traderData.name)
        Loader.UpdateProgression()
    sync_trader_task_complete.rpc(traderPath, taskName)


## Host broadcasts a completed task to every peer. Clients simply append +
## play the cue; host has already written the save.
@rpc("authority", "call_remote", "reliable")
func sync_trader_task_complete(traderPath: String, taskName: String) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    if trader.has_method(&"apply_task_complete"):
        trader.apply_task_complete(taskName)


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


## Host runs Interact on a fire locally and broadcasts the resulting state.
func host_fire_interact(fire: Node) -> void:
    if !_cm.isHost || !is_instance_valid(fire) || !is_instance_valid(_currentScene):
        return
    if !fire.has_method(&"Interact"):
        return
    var firePath: String = _currentScene.get_path_to(fire)
    fire.Interact()
    sync_fire_state.rpc(firePath, fire.active)
    if _cm.DEBUG:
        print("[world_state] host_fire_interact %s active=%s" % [firePath, fire.active])


## Client requests fire interaction from host.
@rpc("any_peer", "call_remote", "reliable")
func request_fire_interact(firePath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(firePath):
        return
    var fire: Node = _scene_node(firePath)
    if !is_instance_valid(fire) || !fire.has_method(&"Interact"):
        return
    host_fire_interact(fire)


## Client receives fire state from host.
@rpc("authority", "call_remote", "reliable")
func sync_fire_state(firePath: String, isActive: bool) -> void:
    var fire: Node = _scene_node(firePath)
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


## Client requests host to detonate a mine (triggered by Detector overlap on client).
@rpc("any_peer", "call_remote", "reliable")
func request_mine_detonate(minePath: String, instant: bool) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(minePath):
        return
    var mine: Node = _scene_node(minePath)
    if !is_instance_valid(mine) || !mine.has_method(&"Detonate"):
        return
    if mine.isDetonated:
        return
    if instant:
        mine.InstantDetonate()
    else:
        mine.Detonate()


## Client receives mine detonation event from host.
@rpc("authority", "call_remote", "reliable")
func receive_mine_detonate(minePath: String, instant: bool) -> void:
    var mine: Node = _scene_node(minePath)
    if !is_instance_valid(mine):
        return
    if instant:
        mine.InstantDetonate()
    else:
        mine.Detonate()

# ---------- Furniture Sync ----------


## Client requests host to update a furniture piece's position after placement.
@rpc("any_peer", "call_remote", "reliable")
func request_furniture_place(furniturePath: String, pos: Vector3, rotY: float) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(furniturePath):
        return
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.global_position = pos
    node.global_rotation_degrees.y = rotY
    sync_furniture_place.rpc(furniturePath, pos, rotY)


## Host broadcasts furniture placement to all peers.
@rpc("authority", "call_remote", "reliable")
func sync_furniture_place(furniturePath: String, pos: Vector3, rotY: float) -> void:
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.global_position = pos
    node.global_rotation_degrees.y = rotY


## Client requests host to remove a cataloged furniture piece.
## Host frees locally and broadcasts via call_remote — acting client
## already ran super.Catalog() which queue_freed its own copy.
@rpc("any_peer", "call_remote", "reliable")
func request_furniture_catalog(furniturePath: String) -> void:
    if !_cm.isHost:
        return
    if !is_valid_path(furniturePath):
        return
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.queue_free()
    sync_furniture_catalog.rpc(furniturePath)


## Host broadcasts furniture removal to all peers.
@rpc("authority", "call_remote", "reliable")
func sync_furniture_catalog(furniturePath: String) -> void:
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.queue_free()


## Any peer grabbed this furniture piece — everyone else holding it drops so
## only the latest grabber's transform wins. Sender's own copy ignores.
@rpc("any_peer", "call_remote", "reliable")
func sync_furniture_grab(furniturePath: String) -> void:
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    if node.has_method(&"force_release"):
        node.force_release()


## Peer released this piece — currently a no-op since sync_furniture_place
## already carries the final pose, but reserved so late-joiners can replay
## the lock history without tripping over stale grabs.
@rpc("any_peer", "call_remote", "reliable")
func sync_furniture_release(_furniturePath: String) -> void:
    pass


# ---------- Coop Settings Sync ----------


## Client asks the host to flip a session-wide setting. Host validates
## [param key] via the defaults dict (unknown keys are refused) and
## broadcasts if accepted.
@rpc("any_peer", "call_remote", "reliable")
func request_setting_change(key: String, value: Variant) -> void:
    if !_cm.isHost:
        return
    if !_cm.settings.has(key):
        return
    _cm.set_setting(key, value)


## Host broadcasts the full settings dict. Simpler than keyed diffs and the
## payload is tiny; mostly fires on setting changes + peer join.
@rpc("authority", "call_remote", "reliable")
func broadcast_settings(newSettings: Dictionary) -> void:
    _cm.settings = newSettings.duplicate()


# ---------- Event System Sync ----------


## Host broadcasts a world event (helicopter, BTR, airdrop, etc.) to all clients.
## Params carry event-specific random values so clients reproduce the exact spawn.
@rpc("authority", "call_remote", "reliable")
func broadcast_event(eventName: String, params: PackedInt32Array) -> void:
    # Host side: record for late-joiner replay before forwarding.
    if _cm != null && _cm.isHost:
        _firedEvents.append([eventName, params])
    var scene: Node = _currentScene
    if !is_instance_valid(scene):
        return
    var eventSystem: Node = scene.get_node_or_null(^"EventSystem")
    if eventSystem == null:
        return
    if eventSystem.has_method(&"receive_event"):
        eventSystem.receive_event(eventName, params)


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
        sync_door_state.rpc_id(peerId, doorPath, obj.isOpen)
        if !obj.locked && obj.key:
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

    # Replay world events (crash sites, vehicles, etc.) for late joiners
    for entry: Array in _firedEvents:
        broadcast_event.rpc_id(peerId, entry[0], entry[1])

    # Push current coop settings so the new peer's simulation/damage patches
    # see the host's tuning instantly.
    broadcast_settings.rpc_id(peerId, _cm.settings)

# ---------- Validation ----------


## Validates a NodePath is safe (no traversal, no absolute paths).
func is_valid_path(nodePath: String) -> bool:
    return !nodePath.is_empty() && !(".." in nodePath) && !nodePath.begins_with("/")
