## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
extends Node


# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")

var gameData: GameData = preload("res://Resources/GameData.tres")


func _log(msg: String) -> void:
    if is_instance_valid(CoopManager):
        CoopManager._log("[world_state] %s" % msg)
    else:
        print("[world_state] %s" % msg)

const PATH_UI: NodePath = ^"Core/UI"
const PATH_INTERFACE: NodePath = ^"Core/UI/Interface"
const PATH_EVENT_SYSTEM: NodePath = ^"EventSystem"
const PATH_DATABASE_ABS: NodePath = ^"/root/Database"

## Cached scene refs, refreshed per scene transition.
var _currentScene: Node = null
var _uiManager: Node = null
var _interface: Node = null
## Database script-constant map — resolved lazily on first pickup lookup.
var _dbConstants: Dictionary = {}
var _dbConstantsReady: bool = false
## Event history for late-joiner replay. Each entry: [eventName, params].
var _firedEvents: Array[Array] = []
## Last broadcast Mines layout (host only) — replayed to late-joining peers.
var lastMineLayout: Array[Dictionary] = []




func refresh_scene_cache() -> void:
    _currentScene = get_tree().current_scene
    _firedEvents.clear()
    if !is_instance_valid(_currentScene):
        _uiManager = null
        _interface = null
        return
    _uiManager = _currentScene.get_node_or_null(PATH_UI)
    _interface = _currentScene.get_node_or_null(PATH_INTERFACE)


## Null-safe lookup against [member _currentScene]. Accepts [String] for RPC-
## delivered paths and wraps them in a [NodePath] (Godot 4.6 requires NodePath
func _scene_node(path: String) -> Node:
    if !is_instance_valid(_currentScene):
        return null
    return _currentScene.get_node_or_null(NodePath(path))


## Item sync: unique sync_id on each dropped item.
## Drops are broadcast by interface_patch.Drop() calling broadcast_item_drop().
## Pickups are broadcast by interactor_patch Item branch calling on_synced_item_picked_up() / request_item_consumed().
var syncedItems: Dictionary = { }
var syncIdCounter: int = 0
var trackingItems: bool = false
var consumedSyncIDs: PackedStringArray = []
var droppedItemHistory: Array[Dictionary] = []
## Client-side queue of local pickups waiting for sync_id confirmation from host.
var pendingDrops: Array[Node] = []

const DROP_RATE_WINDOW_MS: int = 1000
const DROP_RATE_LIMIT: int = 10
const SYNCED_ITEMS_HARD_CAP: int = 500
var _dropRateBuckets: Dictionary[int, PackedInt64Array] = {}


func start_item_tracking() -> void:
    _log("start_item_tracking host=%s" % str(CoopManager.isHost))
    if trackingItems:
        return
    trackingItems = true
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    pendingDrops.clear()
    syncIdCounter = 0


func stop_item_tracking() -> void:
    _log("stop_item_tracking synced=%d pending=%d" % [syncedItems.size(), pendingDrops.size()])
    trackingItems = false
    syncedItems.clear()
    consumedSyncIDs.clear()
    droppedItemHistory.clear()
    pendingDrops.clear()
    syncIdCounter = 0


func broadcast_item_drop(pickup: Node) -> void:
    if !trackingItems || !CoopManager.isActive:
        _log("broadcast_item_drop SKIP tracking=%s active=%s" % [str(trackingItems), str(CoopManager.isActive)])
        return
    var slotData: SlotData = pickup.get(&"slotData")
    if slotData == null || slotData.itemData == null:
        _log("broadcast_item_drop SKIP null slotData")
        return
    var packedSlot: Dictionary = CoopManager.slotSerializer.pack(slotData)
    var pos: Vector3 = pickup.global_position
    var rot: Vector3 = pickup.global_rotation
    if CoopManager.isHost:
        syncIdCounter += 1
        var syncId: String = "drop_%d" % syncIdCounter
        pickup.set_meta(&"sync_id", syncId)
        syncedItems[syncId] = pickup
        droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
        _log("broadcast_item_drop HOST item=%s id=%s pos=%s" % [slotData.itemData.file, syncId, str(pos)])
        sync_item_drop.rpc(syncId, packedSlot, pos, rot)
    else:
        pendingDrops.append(pickup)
        _log("broadcast_item_drop CLIENT requesting item=%s pending=%d" % [slotData.itemData.file, pendingDrops.size()])
        request_item_drop.rpc_id(1, packedSlot, pos, rot)


func on_synced_item_picked_up(syncId: String) -> void:
    _log("on_synced_item_picked_up id=%s host=%s" % [syncId, str(CoopManager.isHost)])
    if !CoopManager.isHost:
        return
    syncedItems.erase(syncId)
    consumedSyncIDs.append(syncId)
    sync_item_consumed.rpc(syncId)


@rpc("authority", "call_remote", "reliable")
func sync_item_drop(syncId: String, packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    _log("sync_item_drop RECV id=%s pos=%s" % [syncId, str(pos)])
    var slotData: SlotData = CoopManager.slotSerializer.unpack(packedSlot)
    if slotData == null:
        _log("sync_item_drop ABORT null slotData id=%s" % syncId)
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        _log("sync_item_drop ABORT scene-not-found file=%s id=%s" % [slotData.itemData.file, syncId])
        return
    var pickup: Node3D = scene.instantiate()
    if !is_instance_valid(_currentScene):
        _log("sync_item_drop ABORT no current scene id=%s" % syncId)
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
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup
    _log("sync_item_drop DONE id=%s file=%s synced=%d" % [syncId, slotData.itemData.file, syncedItems.size()])


@rpc("authority", "call_remote", "reliable")
func sync_item_consumed(syncId: String) -> void:
    _log("sync_item_consumed RECV id=%s tracked=%s" % [syncId, str(syncId in syncedItems)])
    if syncId in syncedItems:
        var node: Node = syncedItems[syncId]
        if is_instance_valid(node):
            node.queue_free()
        syncedItems.erase(syncId)


@rpc("any_peer", "call_remote", "reliable")
func request_item_consumed(syncId: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_item_consumed RECV id=%s from peer=%d" % [syncId, sender])
    if !CoopManager.isHost:
        _log("request_item_consumed REJECT not-host id=%s" % syncId)
        return
    if syncId in syncedItems:
        var node: Node = syncedItems[syncId]
        if is_instance_valid(node):
            node.remove_from_group(&"Item")
            node.queue_free()
        syncedItems.erase(syncId)
        consumedSyncIDs.append(syncId)
        sync_item_consumed.rpc(syncId)
        _log("request_item_consumed DONE id=%s broadcast" % syncId)


@rpc("any_peer", "call_remote", "reliable")
func request_item_drop(packedSlot: Dictionary, pos: Vector3, rot: Vector3) -> void:
    var dropperId: int = multiplayer.get_remote_sender_id()
    _log("request_item_drop RECV from peer=%d pos=%s" % [dropperId, str(pos)])
    if !CoopManager.isHost:
        _log("request_item_drop REJECT not-host peer=%d" % dropperId)
        return
    if !_check_drop_rate(dropperId):
        _log("request_item_drop REJECT rate-limit peer=%d" % dropperId)
        reject_item_drop.rpc_id(dropperId)
        return
    if syncedItems.size() >= SYNCED_ITEMS_HARD_CAP:
        _log("request_item_drop REJECT hard-cap synced=%d" % syncedItems.size())
        reject_item_drop.rpc_id(dropperId)
        return
    var slotData: SlotData = CoopManager.slotSerializer.unpack(packedSlot)
    if slotData == null || slotData.itemData == null:
        _log("request_item_drop REJECT unpack-fail peer=%d" % dropperId)
        reject_item_drop.rpc_id(dropperId)
        return
    var scene: PackedScene = find_pickup_scene(slotData.itemData.file)
    if scene == null:
        _log("request_item_drop REJECT scene-not-found file=%s" % slotData.itemData.file)
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
    pickup.set_meta(&"sync_id", syncId)
    syncedItems[syncId] = pickup
    droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
    # Broadcast to all EXCEPT the dropper (and our own local slot)
    var localPid: int = CoopManager.localPeerId
    for peerId: int in CoopManager.peerGodotIds:
        if peerId == -1 || peerId == localPid || peerId == dropperId:
            continue
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
    if !is_instance_valid(CoopManager) || !CoopManager.isActive:
        return

    if !CoopManager.isHost:
        return

    var frame: int = Engine.get_physics_frames()
    if frame % SIM_SYNC_FRAMES != 0:
        return

    # Every 8th tick (~32s at 60Hz + 240-frame window) send reliable so drift-from-dropped-packet caps.
    if frame % (SIM_SYNC_FRAMES * 8) == 0:
        sync_simulation_reliable.rpc(Simulation.time, Simulation.day, Simulation.weather)
    else:
        sync_simulation.rpc(Simulation.time, Simulation.day, Simulation.weather)



## Host runs Interact on a door locally and broadcasts the resulting state.
## Used by both host's local Interactor patch and by request_door_interact (client path).
func host_door_interact(door: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(door) || !(door is Door) || !is_instance_valid(_currentScene):
        _log("host_door_interact ABORT host=%s valid=%s" % [str(CoopManager.isHost), str(is_instance_valid(door))])
        return
    var doorPath: String = _currentScene.get_path_to(door)
    var wasLocked: bool = door.locked
    door.Interact()
    _log("host_door_interact path=%s isOpen=%s wasLocked=%s nowLocked=%s" % [doorPath, str(door.isOpen), str(wasLocked), str(door.locked)])
    sync_door_state.rpc(doorPath, door.isOpen)
    if wasLocked && !door.locked:
        sync_door_unlock.rpc(doorPath)
        if is_instance_valid(door.linked):
            var linkedPath: String = _currentScene.get_path_to(door.linked)
            sync_door_unlock.rpc(linkedPath)


@rpc("any_peer", "call_remote", "reliable")
func request_door_interact(doorPath: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_door_interact RECV path=%s from peer=%d" % [doorPath, sender])
    if !CoopManager.isHost:
        _log("request_door_interact REJECT not-host")
        return
    if !is_valid_path(doorPath):
        _log("request_door_interact REJECT invalid-path=%s" % doorPath)
        return
    var door: Node = _scene_node(doorPath)
    if !(door is Door):
        _log("request_door_interact REJECT not-a-door path=%s" % doorPath)
        return
    host_door_interact(door)


@rpc("authority", "call_remote", "reliable")
func sync_door_state(doorPath: String, isOpen: bool) -> void:
    _log("sync_door_state RECV path=%s isOpen=%s" % [doorPath, str(isOpen)])
    var door: Node = _scene_node(doorPath)
    if door == null || !(door is Door):
        _log("sync_door_state ABORT resolve-failed path=%s" % doorPath)
        return
    door.isOpen = isOpen
    door.animationTime += 4.0
    door.handleMoving = true
    door.handleTarget = Vector3(0, 0, -45) if door.openAngle.y > 0.0 else Vector3(0, 0, 45)
    door.PlayDoor()


@rpc("authority", "call_remote", "reliable")
func sync_door_unlock(doorPath: String) -> void:
    _log("sync_door_unlock RECV path=%s" % doorPath)
    var door: Node = _scene_node(doorPath)
    if door == null || !(door is Door):
        return
    door.locked = false
    door.PlayUnlock()



func host_switch_interact(sw: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(sw) || !is_instance_valid(_currentScene):
        _log("host_switch_interact ABORT host=%s valid=%s" % [str(CoopManager.isHost), str(is_instance_valid(sw))])
        return
    if !sw.has_method(&"Activate") || !sw.has_method(&"PlaySwitch"):
        _log("host_switch_interact ABORT missing methods")
        return
    var switchPath: String = _currentScene.get_path_to(sw)
    sw.Interact()
    _log("host_switch_interact path=%s active=%s" % [switchPath, str(sw.active)])
    sync_switch_state.rpc(switchPath, sw.active)


@rpc("any_peer", "call_remote", "reliable")
func request_switch_interact(switchPath: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_switch_interact RECV path=%s from peer=%d" % [switchPath, sender])
    if !CoopManager.isHost:
        _log("request_switch_interact REJECT not-host")
        return
    if !is_valid_path(switchPath):
        _log("request_switch_interact REJECT invalid-path")
        return
    var sw: Node = _scene_node(switchPath)
    if sw == null:
        _log("request_switch_interact REJECT resolve-failed")
        return
    host_switch_interact(sw)


@rpc("authority", "call_remote", "reliable")
func sync_switch_state(switchPath: String, active: bool) -> void:
    _log("sync_switch_state RECV path=%s active=%s" % [switchPath, str(active)])
    var sw: Node = _scene_node(switchPath)
    if sw == null:
        return
    if active && !sw.active:
        sw.Activate()
        sw.PlaySwitch()
    elif !active && sw.active:
        sw.Deactivate()
        sw.PlaySwitch()



## Ready-set per bed: peers must all mark the same bed before sleep triggers.
## Resets when sleep fires or when a peer picks a different bed.
var _bedReady: Dictionary[String, PackedInt32Array] = {}


func _expected_peer_count() -> int:
    var n: int = 1  # local
    for pid: int in CoopManager.peerGodotIds:
        if pid != -1:
            n += 1
    return n


func _active_peer_ids() -> Array[int]:
    var out: Array[int] = [CoopManager.localPeerId]
    for pid: int in CoopManager.peerGodotIds:
        if pid != -1:
            out.append(pid)
    return out


func _reset_bed_ready_except(keepPath: String) -> void:
    var toErase: Array[String] = []
    for path: String in _bedReady.keys():
        if path != keepPath:
            toErase.append(path)
    for path: String in toErase:
        _bedReady.erase(path)


func _broadcast_bed_ready(bedPath: String) -> void:
    var readyIds: PackedInt32Array = _bedReady.get(bedPath, PackedInt32Array())
    var total: int = _expected_peer_count()
    CoopManager.set_meta(&"coop_sleep_ready_ids", readyIds.duplicate())
    CoopManager.set_meta(&"coop_sleep_total", total)
    sync_bed_ready.rpc(bedPath, readyIds, total)


## Host side: local or remote peer marked a bed. Trigger sleep when every
## active peer has marked the SAME bed; otherwise just update the overlay.
func host_bed_interact(bed: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(bed) || !is_instance_valid(_currentScene):
        return
    if !bed.has_method(&"Interact") || !bed.canSleep:
        return
    _mark_bed_ready(_currentScene.get_path_to(bed), CoopManager.localPeerId)


func _mark_bed_ready(bedPath: String, peerId: int) -> void:
    if !_active_peer_ids().has(peerId):
        return
    _reset_bed_ready_except(bedPath)
    var readyIds: PackedInt32Array = _bedReady.get(bedPath, PackedInt32Array())
    if !readyIds.has(peerId):
        readyIds.append(peerId)
    _bedReady[bedPath] = readyIds
    var total: int = _expected_peer_count()
    if readyIds.size() >= total:
        _bedReady.erase(bedPath)
        _trigger_sleep(bedPath)
    else:
        _broadcast_bed_ready(bedPath)


func _trigger_sleep(bedPath: String) -> void:
    var bed: Node = _scene_node(bedPath)
    if !is_instance_valid(bed) || !bed.canSleep:
        _log("_trigger_sleep ABORT invalid-bed path=%s" % bedPath)
        return
    var duration: int = int(bed.randomSleep)
    _log("_trigger_sleep path=%s duration=%d total=%d" % [bedPath, duration, _expected_peer_count()])
    # Clear overlay on every peer before sleep audio kicks in.
    CoopManager.set_meta(&"coop_sleep_ready_ids", PackedInt32Array())
    CoopManager.set_meta(&"coop_sleep_total", _expected_peer_count())
    sync_bed_ready.rpc(bedPath, PackedInt32Array(), _expected_peer_count())
    sync_bed_sleep.rpc(bedPath, duration)
    bed.Interact()


@rpc("any_peer", "call_remote", "reliable")
func request_bed_interact(bedPath: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_bed_interact RECV path=%s from peer=%d" % [bedPath, sender])
    if !CoopManager.isHost:
        _log("request_bed_interact REJECT not-host")
        return
    if !is_valid_path(bedPath):
        return
    var bed: Node = _scene_node(bedPath)
    if !is_instance_valid(bed) || !bed.has_method(&"Interact") || !bed.canSleep:
        _log("request_bed_interact REJECT invalid-bed")
        return
    _mark_bed_ready(bedPath, sender)


## Host tells every peer the current ready-set so the overlay renders N/M.
@rpc("authority", "call_remote", "reliable")
func sync_bed_ready(_bedPath: String, readyIds: PackedInt32Array, total: int) -> void:
    CoopManager.set_meta(&"coop_sleep_ready_ids", readyIds.duplicate())
    CoopManager.set_meta(&"coop_sleep_total", total)


## Host broadcasts the sleep fire + duration so clients freeze locally and
## play the transition/sleep audio. Simulation time advances from the host's
## own Bed.Interact() via the normal sync_simulation broadcast.
@rpc("authority", "call_remote", "reliable")
func sync_bed_sleep(bedPath: String, duration: int) -> void:
    var bed: Node = _scene_node(bedPath)
    if !is_instance_valid(bed):
        return
    CoopManager.gameState.apply_sleep_start()
    if bed.has_method(&"PlayTransition"):
        bed.PlayTransition()
    if bed.has_method(&"PlaySleep"):
        bed.PlaySleep()
    await get_tree().create_timer(float(duration), false).timeout
    if !is_instance_valid(self):
        return
    CoopManager.gameState.apply_sleep_end()
    Loader.Message("You slept " + str(duration) + " hours", Color.GREEN)




func host_container_interact(container: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(container) || !(container is LootContainer) || !is_instance_valid(_currentScene):
        _log("host_container_interact ABORT host=%s valid=%s" % [str(CoopManager.isHost), str(is_instance_valid(container))])
        return
    var containerPath: String = _currentScene.get_path_to(container)
    container.Interact()
    var packedLoot: Array[Dictionary] = CoopManager.slotSerializer.pack_array(container.loot)
    _log("host_container_interact path=%s loot=%d" % [containerPath, container.loot.size()])
    sync_container_state.rpc(containerPath, packedLoot)


func host_trader_interact(trader: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(trader) || !trader.has_method(&"Interact"):
        _log("host_trader_interact ABORT host=%s valid=%s" % [str(CoopManager.isHost), str(is_instance_valid(trader))])
        return
    _log("host_trader_interact name=%s" % trader.name)
    trader.Interact()


@rpc("any_peer", "call_remote", "reliable")
func request_container_open(containerPath: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_container_open RECV path=%s from peer=%d" % [containerPath, sender])
    if !CoopManager.isHost:
        _log("request_container_open REJECT not-host")
        return
    if !is_valid_path(containerPath):
        _log("request_container_open REJECT invalid-path")
        return
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        _log("request_container_open REJECT not-a-container path=%s" % containerPath)
        return
    var packedLoot: Array[Dictionary] = CoopManager.slotSerializer.pack_array(container.loot)
    _log("request_container_open GRANT path=%s loot=%d" % [containerPath, container.loot.size()])
    sync_container_open.rpc_id(sender, containerPath, packedLoot)


## Host tells a specific client to open a container with the given loot.
## Sets the loot array first, then calls Interact() to open the UI locally.
@rpc("authority", "call_remote", "reliable")
func sync_container_open(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = CoopManager.slotSerializer.unpack_array(packedLoot)
    # Open the container UI on this client
    if is_instance_valid(_uiManager) && _uiManager.has_method(&"OpenContainer"):
        _uiManager.OpenContainer(container)
        container.ContainerAudio()


@rpc("authority", "call_remote", "reliable")
func sync_container_state(containerPath: String, packedLoot: Array[Dictionary]) -> void:
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.loot = CoopManager.slotSerializer.unpack_array(packedLoot)


## Post-close storage sync — writes to [member LootContainer.storage] (NOT
## .loot), flips storaged=true so [Interface.FillContainerGrid] reads from
## storage on next open. If a peer currently has this container open in the
## UI, rebuild the grid so the change is visible immediately instead of
## stale until reopen.
@rpc("authority", "call_remote", "reliable")
func sync_container_storage(containerPath: String, packedStorage: Array[Dictionary]) -> void:
    var container: Node = _scene_node(containerPath)
    if container == null || !(container is LootContainer):
        return
    container.storage = CoopManager.slotSerializer.unpack_array(packedStorage)
    container.storaged = true
    var iface: Node = _interface
    if is_instance_valid(iface) && iface.get(&"container") == container:
        if iface.has_method(&"ClearContainerGrid"):
            iface.ClearContainerGrid()
        if iface.has_method(&"FillContainerGrid"):
            iface.FillContainerGrid()


## Client → host on Interface.Close after the player has finished moving
## items between container UI and inventory. [param packedStorage] is the
## post-close [member LootContainer.storage] from the client's perspective —
## host adopts it and re-broadcasts via [method sync_container_state] so every
## peer converges on the closer's resulting state. Trust model matches base
## drop/take RPCs: host doesn't reconcile against any opened-state diff, so
## a desynced client could write garbage; container open snapshot is the
## defence (clients only see items they were authorized to take).
@rpc("any_peer", "call_remote", "reliable")
func request_container_set_storage(containerPath: String, packedStorage: Array[Dictionary]) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_container_set_storage RECV path=%s slots=%d from peer=%d" % [containerPath, packedStorage.size(), sender])
    if !CoopManager.isHost:
        _log("request_container_set_storage REJECT not-host")
        return
    if !is_valid_path(containerPath):
        _log("request_container_set_storage REJECT invalid-path")
        return
    var container: Node = _scene_node(containerPath)
    if !is_instance_valid(container) || !(container is LootContainer):
        _log("request_container_set_storage REJECT not-a-container")
        return
    container.storage = CoopManager.slotSerializer.unpack_array(packedStorage)
    container.storaged = true
    sync_container_storage.rpc(containerPath, packedStorage)
    _log("request_container_set_storage GRANT path=%s slots=%d" % [containerPath, packedStorage.size()])


@rpc("any_peer", "call_remote", "reliable")
func request_container_take_item(containerPath: String, itemIndex: int) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_container_take_item RECV path=%s idx=%d from peer=%d" % [containerPath, itemIndex, sender])
    if !CoopManager.isHost:
        _log("request_container_take_item REJECT not-host")
        return
    if !is_valid_path(containerPath):
        return
    var container: Node = _scene_node(containerPath)
    if !is_instance_valid(container) || !(container is LootContainer):
        _log("request_container_take_item REJECT not-a-container")
        return
    if itemIndex < 0 || itemIndex >= container.loot.size():
        _log("request_container_take_item REJECT bad-idx idx=%d size=%d" % [itemIndex, container.loot.size()])
        return
    var takenSlot: SlotData = container.loot[itemIndex]
    if takenSlot == null:
        _log("request_container_take_item REJECT null-slot idx=%d" % itemIndex)
        return
    # Remove from host's authoritative loot array
    container.loot.remove_at(itemIndex)
    _log("request_container_take_item GRANT item=%s to peer=%d remaining=%d" % [takenSlot.itemData.file if takenSlot.itemData != null else "?", sender, container.loot.size()])
    # Send item to requesting client
    grant_pickup_to_client.rpc_id(sender, CoopManager.slotSerializer.pack(takenSlot))
    # Broadcast updated loot to all peers
    sync_container_state.rpc(containerPath, CoopManager.slotSerializer.pack_array(container.loot))

@rpc("authority", "call_remote", "reliable")
func grant_pickup_to_client(packedSlot: Dictionary) -> void:
    var slotData: SlotData = CoopManager.slotSerializer.unpack(packedSlot)
    if slotData == null:
        _log("grant_pickup_to_client ABORT unpack-fail")
        return
    var iface: Node = _interface
    if !is_instance_valid(iface):
        _log("grant_pickup_to_client ABORT no-interface")
        return
    if iface.AutoStack(slotData, iface.inventoryGrid):
        _log("grant_pickup_to_client STACKED item=%s" % slotData.itemData.file)
        iface.UpdateStats(false)
    elif iface.Create(slotData, iface.inventoryGrid, false):
        _log("grant_pickup_to_client CREATED item=%s" % slotData.itemData.file)
        iface.UpdateStats(false)
    else:
        _log("grant_pickup_to_client FAILED no-room item=%s" % slotData.itemData.file)



func find_pickup_scene(fileKey: String) -> PackedScene:
    if !_dbConstantsReady:
        var db: Node = get_node_or_null(PATH_DATABASE_ABS)
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
func register_scene_items() -> void:
    if !CoopManager.isHost || !trackingItems:
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
        var packedSlot: Dictionary = CoopManager.slotSerializer.pack(slotData)
        var pos: Vector3 = node.global_position
        var rot: Vector3 = node.global_rotation
        droppedItemHistory.append({&"id": syncId, &"slot": packedSlot, &"pos": pos, &"rot": rot})
        sync_item_drop.rpc(syncId, packedSlot, pos, rot)
    CoopManager._log("register_scene_items: registered=%d skipped=%d total_in_group=%d" % [
        itemCount, skippedCount, itemCount + skippedCount])


@rpc("any_peer", "call_remote", "reliable")
func request_trader_open(traderPath: String) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_trader_open RECV path=%s from peer=%d" % [traderPath, sender])
    if !CoopManager.isHost:
        _log("request_trader_open REJECT not-host")
        return
    if !is_valid_path(traderPath):
        _log("request_trader_open REJECT invalid-path")
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader) || !trader.has_method(&"Interact"):
        _log("request_trader_open REJECT not-a-trader")
        return
    var packedSupply: Array[Dictionary] = CoopManager.slotSerializer.pack_array(trader.supply)
    var tax: int = int(trader.tax)
    _log("request_trader_open GRANT supply=%d tax=%d to peer=%d" % [packedSupply.size(), tax, sender])
    sync_trader_supply.rpc_id(sender, traderPath, packedSupply, tax)


@rpc("authority", "call_remote", "reliable")
func sync_trader_supply(traderPath: String, packedSupply: Array[Dictionary], tax: int) -> void:
    _log("sync_trader_supply RECV path=%s supply=%d tax=%d" % [traderPath, packedSupply.size(), tax])
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        _log("sync_trader_supply ABORT resolve-failed")
        return
    # Replace local supply with host's authoritative copy.
    trader.supply = CoopManager.slotSerializer.unpack_array(packedSupply)
    trader.tax = tax
    var uiMgr: Node = _uiManager
    if is_instance_valid(uiMgr) && uiMgr.has_method(&"OpenTrader"):
        uiMgr.OpenTrader(trader)


@rpc("any_peer", "call_remote", "reliable")
func request_trade(traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_trade RECV path=%s requested=%d offered=%d from peer=%d" % [traderPath, requestedIndices.size(), offeredSlots.size(), sender])
    if !CoopManager.isHost:
        _log("request_trade REJECT not-host")
        return
    if !is_valid_path(traderPath):
        _log("request_trade REJECT invalid-path")
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        _log("request_trade REJECT resolve-failed")
        return
    var requesterId: int = sender

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
    var offeredItems: Array[SlotData] = CoopManager.slotSerializer.unpack_array(offeredSlots)
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

    # Grant items to requester. Host-local call (requesterId == 0) means the
    # host itself is buying — rpc_id(0) skips self, so apply the grant logic
    # directly instead of routing through the RPC.
    var grantedSlots: Array[Dictionary] = CoopManager.slotSerializer.pack_array(requestedItems)
    _log("request_trade GRANT requesterId=%d granted=%d offerValue=%.1f reqValue=%.1f" % [requesterId, grantedSlots.size(), offerValue, requestValue])
    if requesterId == 0:
        _log("request_trade host-local-apply (requesterId=0)")
        _apply_trade_granted(grantedSlots)
    else:
        _log("request_trade rpc_id->%d sync_trade_granted" % requesterId)
        sync_trade_granted.rpc_id(requesterId, grantedSlots)

    # Broadcast updated supply to all peers.
    var packedSupply: Array[Dictionary] = CoopManager.slotSerializer.pack_array(trader.supply)
    sync_trader_supply_update.rpc(traderPath, packedSupply)


@rpc("authority", "call_remote", "reliable")
func reject_trade() -> void:
    CoopManager._log("[Trader] Trade rejected by host")
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
    _log("sync_trade_granted RECV granted=%d" % grantedSlots.size())
    _apply_trade_granted(grantedSlots)


## Local grant implementation shared by [method sync_trade_granted] (remote
## client receiving grant) and [method request_trade] (host purchasing on
func _apply_trade_granted(grantedSlots: Array[Dictionary]) -> void:
    var iface: Node = _interface
    _log("_apply_trade_granted granted=%d iface_valid=%s" % [grantedSlots.size(), str(is_instance_valid(iface))])
    _remove_pending_trade_elements(iface)
    remove_meta(&"_pending_trade_elements")

    if !is_instance_valid(iface):
        _log("_apply_trade_granted ABORT no iface")
        return
    var created: int = 0
    for packed: Dictionary in grantedSlots:
        var slot: SlotData = CoopManager.slotSerializer.unpack(packed)
        if slot == null:
            _log("_apply_trade_granted SKIP unpack-null")
            continue
        var targetGrid: Node = iface.catalogGrid if slot.itemData.type == "Furniture" else iface.inventoryGrid
        var updateStacks: bool = slot.itemData.type != "Furniture"
        _log("_apply_trade_granted CREATE item=%s type=%s grid=%s" % [slot.itemData.file, slot.itemData.type, targetGrid.name if is_instance_valid(targetGrid) else "<null>"])
        iface.Create(slot, targetGrid, updateStacks)
        created += 1
    iface.UpdateStats(false)
    _log("_apply_trade_granted DONE created=%d" % created)


func _remove_pending_trade_elements(iface: Node) -> void:
    if !is_instance_valid(iface):
        return
    var pending: Array = get_meta(&"_pending_trade_elements", [])
    for element: Node in pending:
        if !is_instance_valid(element):
            continue
        iface.inventoryGrid.Pick(element)
        element.queue_free()


@rpc("authority", "call_remote", "reliable")
func sync_trader_supply_update(traderPath: String, packedSupply: Array[Dictionary]) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    trader.supply = CoopManager.slotSerializer.unpack_array(packedSupply)
    # Refresh the supply grid if this trader is currently open.
    var iface: Node = _interface
    if is_instance_valid(iface) && is_instance_valid(iface.trader) && iface.trader == trader:
        if iface.has_method(&"Resupply"):
            iface.Resupply()


## Client asks host to mark a task as completed. Host applies locally
## (including the Traders.tres save — host is authoritative for disk) and
## broadcasts to every peer. Matches [method Trader.CompleteTask] side
## effects across the session so no one double-completes.
## Any rejection path sends reject_trader_task_complete back to the sender so
## [method interface_patch.reject_pending_task] can restore hidden inputs.
@rpc("any_peer", "call_remote", "reliable")
func request_trader_task_complete(traderPath: String, taskName: String) -> void:
    if !CoopManager.isHost:
        return
    var senderId: int = multiplayer.get_remote_sender_id()
    if !is_valid_path(traderPath):
        reject_trader_task_complete.rpc_id(senderId, taskName)
        return
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        reject_trader_task_complete.rpc_id(senderId, taskName)
        return
    if trader.tasksCompleted.has(taskName):
        reject_trader_task_complete.rpc_id(senderId, taskName)
        return
    # Validate task belongs to this trader's declared task list. Protects
    # against clients spoofing unrelated taskNames (wrong trader, unknown
    # name, empty string) to grab rewards without the input items.
    var traderData: Resource = trader.get(&"traderData")
    if !is_instance_valid(traderData):
        reject_trader_task_complete.rpc_id(senderId, taskName)
        return
    var tasks: Variant = traderData.get(&"tasks")
    if tasks == null || !(tasks is Array) || (tasks as Array).is_empty():
        reject_trader_task_complete.rpc_id(senderId, taskName)
        return
    var known: bool = false
    for taskData: Resource in tasks as Array:
        if is_instance_valid(taskData) && taskData.name == taskName:
            known = true
            break
    if !known:
        var dataName: Variant = traderData.get(&"name")
        push_warning("[world_state] Rejecting trader task '%s' from peer %d — not in %s tasks" % [taskName, senderId, dataName if dataName != null else "?"])
        reject_trader_task_complete.rpc_id(senderId, taskName)
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
    # Targeted ack so only the requester finalises its hidden inputs + spawns
    # rewards. A broadcast finalize would duplicate rewards for peers that
    # staged the same task concurrently.
    ack_trader_task_complete.rpc_id(senderId, taskName)


## Host broadcasts a completed task to every peer. Clients simply append +
## play the cue; host has already written the save.
@rpc("authority", "call_remote", "reliable")
func sync_trader_task_complete(traderPath: String, taskName: String) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    if trader.tasksCompleted.has(taskName):
        return
    trader.tasksCompleted.append(taskName)
    if trader.has_method(&"PlayTraderTask"):
        trader.PlayTraderTask()
    Loader.Message("Task Completed: " + taskName, Color.GREEN)


## Full tasksCompleted snapshot for one trader — sent to each peer on join so
## clients never see a fresh trader board before host's state lands.
@rpc("authority", "call_remote", "reliable")
func sync_trader_tasks_snapshot(traderPath: String, tasks: Array) -> void:
    var trader: Node = _scene_node(traderPath)
    if !is_instance_valid(trader):
        return
    trader.tasksCompleted.clear()
    for t: Variant in tasks:
        if t is String:
            trader.tasksCompleted.append(t)


## Host tells the requester their deferred completion succeeded. Client
## finalises the pending bundle from interface_hooks._on_complete by
## destroying hidden inputs + spawning rewards under host authority.
@rpc("authority", "call_remote", "reliable")
func ack_trader_task_complete(taskName: String) -> void:
    if is_instance_valid(_interface) && CoopManager.interfaceHooks != null:
        CoopManager.interfaceHooks.finalize_pending_task(_interface, taskName)


## Host tells the requesting client the task was refused. Client restores
## the hidden inputs and shows an error — nothing else changes.
@rpc("authority", "call_remote", "reliable")
func reject_trader_task_complete(taskName: String) -> void:
    if is_instance_valid(_interface) && CoopManager.interfaceHooks != null:
        CoopManager.interfaceHooks.reject_pending_task(_interface, taskName)




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



func broadcast_fire_state(firePath: String, isActive: bool) -> void:
    sync_fire_state.rpc(firePath, isActive)


func host_fire_interact(fire: Node) -> void:
    if !CoopManager.isHost || !is_instance_valid(fire) || !is_instance_valid(_currentScene):
        return
    if !fire.has_method(&"Interact"):
        return
    var firePath: String = _currentScene.get_path_to(fire)
    fire.Interact()
    sync_fire_state.rpc(firePath, fire.active)
    if CoopManager.DEBUG:
        print("[world_state] host_fire_interact %s active=%s" % [firePath, fire.active])


@rpc("any_peer", "call_remote", "reliable")
func request_fire_interact(firePath: String) -> void:
    if !CoopManager.isHost:
        return
    if !is_valid_path(firePath):
        return
    var fire: Node = _scene_node(firePath)
    if !is_instance_valid(fire) || !fire.has_method(&"Interact"):
        return
    host_fire_interact(fire)


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



func broadcast_mine_detonate(minePath: String, instant: bool) -> void:
    receive_mine_detonate.rpc(minePath, instant)


@rpc("any_peer", "call_remote", "reliable")
func request_mine_detonate(minePath: String, instant: bool) -> void:
    if !CoopManager.isHost:
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


@rpc("authority", "call_remote", "reliable")
func receive_mine_detonate(minePath: String, instant: bool) -> void:
    var mine: Node = _scene_node(minePath)
    if !is_instance_valid(mine):
        return
    if instant:
        mine.InstantDetonate()
    else:
        mine.Detonate()


## Pushes captured Mines layout to one or all peers. Sent on host capture (rpc to all)
## and on late-join request (rpc_id to requester).
@rpc("authority", "call_remote", "reliable")
func broadcast_mine_layout(layout: Array) -> void:
    CoopManager.mineSpawnerHook.apply_layout(layout)


## Late-joiner asks host for current Mines layout. Host echoes lastMineLayout if non-empty.
@rpc("any_peer", "call_remote", "reliable")
func request_mine_layout() -> void:
    if !CoopManager.isHost:
        return
    var senderId: int = multiplayer.get_remote_sender_id()
    if lastMineLayout.is_empty():
        return
    broadcast_mine_layout.rpc_id(senderId, lastMineLayout)



@rpc("any_peer", "call_remote", "reliable")
func request_furniture_place(furniturePath: String, pos: Vector3, rotY: float) -> void:
    if !CoopManager.isHost:
        return
    if !is_valid_path(furniturePath):
        return
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.global_position = pos
    node.global_rotation_degrees.y = rotY
    sync_furniture_place.rpc(furniturePath, pos, rotY)


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
    if !CoopManager.isHost:
        return
    if !is_valid_path(furniturePath):
        return
    var node: Node = _scene_node(furniturePath)
    if !is_instance_valid(node):
        return
    node.queue_free()
    sync_furniture_catalog.rpc(furniturePath)


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
    # TODO post-hook-migration: force_release helper no longer exists on
    # vanilla Furniture. Walk `node`'s Furniture-script children + call
    # ResetMove via CoopManager.furnitureHooks.suppress_sync if multi-grab
    # becomes a visible bug. Edge case auto-resolves on next ResetMove
    # broadcast in practice.


## Peer released this piece — currently a no-op since sync_furniture_place
## already carries the final pose, but reserved so late-joiners can replay
## the lock history without tripping over stale grabs.
@rpc("any_peer", "call_remote", "reliable")
func sync_furniture_release(_furniturePath: String) -> void:
    pass




## Client asks the host to flip a session-wide setting. Host validates
## [param key] via the defaults dict (unknown keys are refused) and
## broadcasts if accepted.
@rpc("any_peer", "call_remote", "reliable")
func request_setting_change(key: String, value: Variant) -> void:
    var sender: int = multiplayer.get_remote_sender_id()
    _log("request_setting_change RECV key=%s value=%s from peer=%d" % [key, str(value), sender])
    if !CoopManager.isHost:
        _log("request_setting_change REJECT not-host")
        return
    if !CoopManager.settings.has(key):
        _log("request_setting_change REJECT unknown-key=%s" % key)
        return
    var t: int = typeof(value)
    if t != TYPE_FLOAT && t != TYPE_INT:
        _log("request_setting_change REJECT bad-type=%d" % t)
        return
    var f: float = clampf(float(value), 0.0, 1000.0)
    CoopManager.set_setting(key, f)
    _log("request_setting_change APPLIED key=%s value=%f" % [key, f])


## Host broadcasts the full settings dict. Simpler than keyed diffs and the
## payload is tiny; mostly fires on setting changes + peer join.
@rpc("authority", "call_remote", "reliable")
func broadcast_settings(newSettings: Dictionary) -> void:
    _log("broadcast_settings RECV keys=%d" % newSettings.size())
    CoopManager.settings = newSettings.duplicate()




## Host broadcasts a world event (helicopter, BTR, airdrop, etc.) to all clients.
## Params carry event-specific random values so clients reproduce the exact spawn.
@rpc("authority", "call_remote", "reliable")
func broadcast_event(eventName: String, params: PackedInt32Array) -> void:
    # Host side: record for late-joiner replay before forwarding.
    if CoopManager != null && CoopManager.isHost:
        _firedEvents.append([eventName, params])
    var scene: Node = _currentScene
    if !is_instance_valid(scene):
        return
    var eventSystem: Node = scene.get_node_or_null(PATH_EVENT_SYSTEM)
    if eventSystem == null:
        return
    # Hook-migration path: receive_event helper no longer on vanilla
    # EventSystem; routed through CoopManager.eventSystemHooks.
    if CoopManager.eventSystemHooks != null:
        CoopManager.eventSystemHooks.dispatch_event(eventSystem, eventName, params)
    elif eventSystem.has_method(&"receive_event"):
        eventSystem.receive_event(eventName, params)




## Sends the current world state to a specific peer (called by host on peer connect).
func send_full_state(peerId: int) -> void:
    if !CoopManager.isHost:
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
    broadcast_settings.rpc_id(peerId, CoopManager.settings)

    # Push host's authoritative trader task completion state so a new client
    # can't re-complete a task already finished by the host before join.
    for traderNode: Node in tree.get_nodes_in_group(&"Trader"):
        if !is_instance_valid(traderNode) || !(&"tasksCompleted" in traderNode):
            continue
        var traderPath: String = scene.get_path_to(traderNode)
        sync_trader_tasks_snapshot.rpc_id(peerId, traderPath, traderNode.tasksCompleted.duplicate())



func is_valid_path(nodePath: String) -> bool:
    return !nodePath.is_empty() && !(".." in nodePath) && !nodePath.begins_with("/")


func _is_valid_audio_path(clipPath: String) -> bool:
    if clipPath.is_empty() || !clipPath.begins_with("res://") || ".." in clipPath:
        return false
    var lower: String = clipPath.to_lower()
    return lower.ends_with(".ogg") || lower.ends_with(".wav") || lower.ends_with(".mp3")


func _check_drop_rate(peerId: int) -> bool:
    var now: int = Time.get_ticks_msec()
    var cutoff: int = now - DROP_RATE_WINDOW_MS
    var bucket: PackedInt64Array = _dropRateBuckets.get(peerId, PackedInt64Array())
    while bucket.size() > 0 && bucket[0] < cutoff:
        bucket.remove_at(0)
    if bucket.size() >= DROP_RATE_LIMIT:
        _dropRateBuckets[peerId] = bucket
        return false
    bucket.append(now)
    _dropRateBuckets[peerId] = bucket
    return true


## Host launched MissileSpawner prepare — clients spawn hidden missile pool so
## later broadcast_missile_launch(index) resolves to a real child.
func _has_execute_launch(n: Node) -> bool:
    return n.has_method(&"ExecuteLaunch")


@rpc("authority", "call_remote", "reliable")
func broadcast_missile_prepare(spawnerPath: String) -> void:
    var spawner: Node = _scene_node(spawnerPath)
    if spawner == null || !spawner.has_method(&"ExecutePrepareMissiles"):
        return
    var existing: Array = spawner.get_children().filter(_has_execute_launch)
    if existing.is_empty():
        spawner.ExecutePrepareMissiles(true)


## Host launched one missile from the pool. Client mirrors visibility + launch.
## [param poolIndex] is the index into the FILTERED pool (ExecuteLaunch-capable children)
## so unrelated siblings added by the base game don't desync the mapping.
@rpc("authority", "call_remote", "reliable")
func broadcast_missile_launch(spawnerPath: String, poolIndex: int) -> void:
    var spawner: Node = _scene_node(spawnerPath)
    if spawner == null:
        return
    var pool: Array = spawner.get_children().filter(_has_execute_launch)
    if poolIndex < 0 || poolIndex >= pool.size():
        return
    var child: Node = pool[poolIndex]
    if !is_instance_valid(child):
        return
    spawner.launched = true
    if child is Node3D:
        (child as Node3D).visible = true
    child.ExecuteLaunch(true)


## Host RocketHelicopter hit terrain — clients spawn explosion at pos and the
## authoritative node will queue_free itself locally via vehicle_state staleness.
@rpc("authority", "call_remote", "reliable")
func broadcast_rocket_explode(pos: Vector3) -> void:
    var scene: Node = _currentScene
    if !is_instance_valid(scene):
        return
    var packed: PackedScene = load("res://Effects/Explosion.tscn") as PackedScene
    if packed == null:
        return
    var instance: Node = packed.instantiate()
    get_tree().get_root().add_child(instance)
    if instance is Node3D:
        (instance as Node3D).global_position = pos
    if "size" in instance:
        instance.size = 20.0
    if instance.has_method(&"Explode"):
        instance.Explode()


## Host rocket left range — no-op marker; clients let vehicle_state drop the
## snapshot and the rocket queue_frees itself when broadcasts stop.
@rpc("authority", "call_remote", "reliable")
func broadcast_rocket_cleanup(_pos: Vector3) -> void:
    pass


## Host CASA airdrop drop/release edge. Client airdrop runs `set_as_top_level`
## in casa_patch._ready, so no reparent RPC is needed — client airdrop body
## lerps independently from its own pose snapshot regardless of the plane.
@rpc("authority", "call_remote", "reliable")
func broadcast_airdrop_state(casaPath: String, isDropped: bool, isReleased: bool) -> void:
    var casa: Node = _scene_node(casaPath)
    if casa == null:
        return
    casa.dropped = isDropped
    casa.released = isReleased
    if isDropped:
        var airdropVar: Variant = casa.get(&"airdrop")
        if airdropVar != null && airdropVar is Node3D && is_instance_valid(airdropVar):
            (airdropVar as Node3D).visible = true


## Per-peer live instrument audio spawned on remote_player.
var _remoteInstrumentAudio: Dictionary = {}


func _stop_remote_instrument(peerId: int) -> void:
    if !_remoteInstrumentAudio.has(peerId):
        return
    var audio: Node = _remoteInstrumentAudio[peerId]
    _remoteInstrumentAudio.erase(peerId)
    if is_instance_valid(audio):
        audio.queue_free()


func _play_remote_instrument(peerId: int, clipPath: String) -> void:
    _stop_remote_instrument(peerId)
    if !_is_valid_audio_path(clipPath):
        return
    var idx: int = CoopManager.peer_idx(peerId)
    if idx < 0 || idx >= CoopManager.remoteNodes.size():
        return
    var remote: Node3D = CoopManager.remoteNodes[idx]
    if !is_instance_valid(remote):
        return
    var clip: AudioStream = load(clipPath) as AudioStream
    if clip == null:
        return
    var audio: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
    audio.stream = clip
    audio.max_distance = 50.0
    audio.unit_size = 6.0
    audio.bus = &"Master"
    remote.add_child(audio)
    audio.play()
    _remoteInstrumentAudio[peerId] = audio


@rpc("any_peer", "call_remote", "reliable")
func request_instrument_play(clipPath: String) -> void:
    if !CoopManager.isHost:
        return
    if !_is_valid_audio_path(clipPath):
        return
    var sender: int = multiplayer.get_remote_sender_id()
    broadcast_instrument_play.rpc(sender, clipPath)


@rpc("any_peer", "call_remote", "reliable")
func request_instrument_stop() -> void:
    if !CoopManager.isHost:
        return
    var sender: int = multiplayer.get_remote_sender_id()
    broadcast_instrument_stop.rpc(sender)


@rpc("authority", "call_remote", "reliable")
func broadcast_instrument_play(peerId: int, clipPath: String) -> void:
    if peerId == multiplayer.get_unique_id():
        return
    _play_remote_instrument(peerId, clipPath)


@rpc("authority", "call_remote", "reliable")
func broadcast_instrument_stop(peerId: int) -> void:
    if peerId == multiplayer.get_unique_id():
        return
    _stop_remote_instrument(peerId)


## Host-local toggle path used by coop_interact_router when host presses Interact
## on a Radio/Television. Runs vanilla Interact, then broadcasts so every peer
## stays in sync.
func host_interact_toggle(target: Node) -> void:
    if !is_instance_valid(target) || !target.has_method(&"Interact"):
        return
    target.Interact()
    if !is_instance_valid(_currentScene):
        return
    broadcast_interact_toggle.rpc(String(_currentScene.get_path_to(target)))


## Client requests host to toggle a node's Interact (Radio/TV). Host runs it
## then broadcasts so every peer stays in sync.
@rpc("any_peer", "call_remote", "reliable")
func request_interact_toggle(nodePath: String) -> void:
    if !CoopManager.isHost:
        return
    if !is_valid_path(nodePath):
        return
    var node: Node = _scene_node(nodePath)
    if !is_instance_valid(node) || !node.has_method(&"Interact"):
        return
    node.Interact()
    broadcast_interact_toggle.rpc(nodePath)


## Host tells every peer to run the same toggled Interact locally.
@rpc("authority", "call_remote", "reliable")
func broadcast_interact_toggle(nodePath: String) -> void:
    var node: Node = _scene_node(nodePath)
    if !is_instance_valid(node) || !node.has_method(&"Interact"):
        return
    node.Interact()


## Client asks host to accept its cat-state delta. Host applies + rebroadcasts.
@rpc("any_peer", "call_remote", "reliable")
func request_cat_state(catFound: bool, catDead: bool, catHydration: float) -> void:
    if !CoopManager.isHost:
        return
    if !CoopManager.gameState.apply_cat_state_host(catFound, catDead, catHydration):
        return
    broadcast_cat_state.rpc(gameData.catFound, gameData.catDead, gameData.cat)


## Host pushes authoritative cat state; monotonic (found/dead latch true).
@rpc("authority", "call_remote", "reliable")
func broadcast_cat_state(catFound: bool, catDead: bool, catHydration: float) -> void:
    CoopManager.gameState.apply_cat_state_client(catFound, catDead, catHydration)


## Host CASA airdrop landed — spawn hotspot + play bounce sound locally.
@rpc("authority", "call_remote", "reliable")
func broadcast_airdrop_landing(pos: Vector3) -> void:
    var scene: Node = _currentScene
    if !is_instance_valid(scene):
        return
    var aiRoot: Node = scene.get_node_or_null(^"AI")
    if aiRoot != null && aiRoot.has_method(&"CreateHotspot"):
        aiRoot.CreateHotspot(pos, false)
