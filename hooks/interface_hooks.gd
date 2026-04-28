## Hook callbacks for Interface.gd — drop/trade/task broadcasts; defers client task completion until host ACK.
## Replaces patches/interface_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Per-instance pending-task state in dict keyed by Interface node.
## Public finalize_pending_task / reject_pending_task called from world_state RPC handlers.
extends RefCounted


const PATH_MAP: NodePath = ^"/root/Map"

var _lib: Object = null
# Captured container ref between interface-close-pre and -post (vanilla nulls self.container).
var _heldContainer: Dictionary[Node, Node] = {}
# Pending task completions awaiting host ACK, keyed by interface then by task name.
var _pendingTasks: Dictionary[Node, Dictionary] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("interface-close-pre", _on_close_pre)
    lib.hook("interface-close-post", _on_close_post)
    lib.hook("interface-drop", _on_drop)
    lib.hook("interface-completedeal", _on_complete_deal)
    lib.hook("interface-complete", _on_complete)


func _on_close_pre() -> void:
    var iface: Node = _lib._caller
    if iface == null:
        return
    _heldContainer[iface] = iface.container


func _on_close_post() -> void:
    var iface: Node = _lib._caller
    if iface == null:
        return
    var heldContainer: Node = _heldContainer.get(iface, null)
    _heldContainer.erase(iface)
    if !CoopManager.is_session_active():
        return
    if !is_instance_valid(heldContainer) || !(heldContainer is LootContainer):
        return
    var scene: Node = iface.get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var path: String = scene.get_path_to(heldContainer)
    var packedStorage: Array[Dictionary] = CoopManager.slotSerializer.pack_array(heldContainer.storage)
    CoopManager._log("[interface] Close container=%s slots=%d host=%s" % [path, packedStorage.size(), str(CoopManager.isHost)])
    if CoopManager.isHost:
        CoopManager.worldState.sync_container_storage.rpc(path, packedStorage)
    else:
        CoopManager.worldState.request_container_set_storage.rpc_id(1, path, packedStorage)


func _on_drop(target: Node) -> void:
    var iface: Node = _lib._caller
    if iface == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla Drop runs.
    _lib.skip_super()

    var itemName: String = target.slotData.itemData.name if target.slotData != null && target.slotData.itemData != null else "<unknown>"
    var stackable: bool = target.slotData.itemData.stackable if target.slotData != null && target.slotData.itemData != null else false
    var amount: int = target.slotData.amount if target.slotData != null else 0
    CoopManager._log("[interface] Drop item=%s stackable=%s amount=%d host=%s" % [itemName, str(stackable), amount, str(CoopManager.isHost)])

    var map: Node = iface.get_tree().current_scene.get_node(PATH_MAP)
    var file: PackedScene = Database.get(target.slotData.itemData.file)

    if !file:
        CoopManager._log("[interface] Drop FAIL file_missing=%s" % itemName)
        target.queue_free()
        iface.PlayDrop()
        return

    var transform: Dictionary = _resolve_drop_transform(iface)
    var dropForce: float = 2.5

    if stackable:
        _spawn_stackable_drops(file, target, map, transform, dropForce)
    else:
        _spawn_single_drop(file, target, map, transform, dropForce)

    target.reparent(iface)
    target.queue_free()
    iface.PlayDrop()
    iface.UpdateStats(true)


func _resolve_drop_transform(iface: Node) -> Dictionary:
    var dir: Vector3 = Vector3.ZERO
    var pos: Vector3 = Vector3.ZERO
    var rot: Vector3 = Vector3.ZERO

    if is_instance_valid(iface.trader) && iface.hoverGrid == null:
        dir = iface.trader.global_transform.basis.z
        pos = (iface.trader.global_position + Vector3(0, 1.0, 0)) + dir / 2
        rot = Vector3(-25, iface.trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif !is_instance_valid(iface.trader) && (iface.hoverGrid == null || iface.hoverGrid.get_parent().name == "Inventory"):
        dir = -iface.camera.global_transform.basis.z
        pos = (iface.camera.global_position + Vector3(0, -0.25, 0)) + dir / 2
        rot = Vector3(-25, iface.camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif !is_instance_valid(iface.trader) && iface.hoverGrid.get_parent().name == "Container":
        dir = iface.container.global_transform.basis.z
        pos = (iface.container.global_position + Vector3(0, 0.5, 0)) + dir / 2
        rot = Vector3(-25, iface.container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)

    return {"direction": dir, "position": pos, "rotation": rot}


func _spawn_stackable_drops(file: PackedScene, target: Node, map: Node, transform: Dictionary, dropForce: float) -> void:
    var boxSize: int = target.slotData.itemData.defaultAmount
    var boxesNeeded: int = ceili(float(target.slotData.amount) / float(boxSize))
    var amountLeft: int = target.slotData.amount

    for i: int in range(boxesNeeded):
        var pickup: Node3D = _instantiate_pickup(file, map, transform, dropForce)

        var newSlotData: SlotData = SlotData.new()
        newSlotData.itemData = target.slotData.itemData
        if amountLeft > boxSize:
            amountLeft -= boxSize
            newSlotData.amount = boxSize
        else:
            newSlotData.amount = amountLeft
        pickup.slotData.Update(newSlotData)

        CoopManager.worldState.broadcast_item_drop(pickup)


func _spawn_single_drop(file: PackedScene, target: Node, map: Node, transform: Dictionary, dropForce: float) -> void:
    var pickup: Node3D = _instantiate_pickup(file, map, transform, dropForce)
    pickup.slotData.Update(target.slotData)
    pickup.UpdateAttachments()
    CoopManager.worldState.broadcast_item_drop(pickup)


func _instantiate_pickup(file: PackedScene, map: Node, transform: Dictionary, dropForce: float) -> Node3D:
    var pickup: Node3D = file.instantiate()
    map.add_child(pickup)
    pickup.position = transform.position
    pickup.rotation_degrees = transform.rotation
    pickup.linear_velocity = transform.direction * dropForce
    pickup.Unfreeze()
    return pickup


func _on_complete_deal() -> void:
    var iface: Node = _lib._caller
    if iface == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla CompleteDeal runs.
    _lib.skip_super()
    if !is_instance_valid(iface.trader):
        return

    var requestedIndices: PackedInt32Array = _collect_requested_supply_indices(iface)
    var offeredSlots: Array[Dictionary] = _collect_offered_inventory_slots(iface)

    if requestedIndices.is_empty():
        return

    var traderPath: String = iface.get_tree().current_scene.get_path_to(iface.trader)
    CoopManager._log("[interface] CompleteDeal trader=%s req=%d offered=%d host=%s" % [traderPath, requestedIndices.size(), offeredSlots.size(), str(CoopManager.isHost)])
    if CoopManager.isHost:
        _execute_host_trade(iface, traderPath, requestedIndices, offeredSlots)
    else:
        _execute_client_trade(iface, traderPath, requestedIndices, offeredSlots)


func _collect_requested_supply_indices(iface: Node) -> PackedInt32Array:
    var out: PackedInt32Array = []
    var supplyChildren: Array[Node] = iface.supplyGrid.get_children()
    for i: int in supplyChildren.size():
        if supplyChildren[i].selected:
            out.append(i)
    return out


func _collect_offered_inventory_slots(iface: Node) -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    for element: Node in iface.inventoryGrid.get_children():
        if element.selected:
            out.append(CoopManager.slotSerializer.pack(element.slotData))
    return out


func _execute_host_trade(iface: Node, traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    CoopManager.worldState.request_trade(traderPath, requestedIndices, offeredSlots)
    for element: Node in iface.inventoryGrid.get_children():
        if element.selected:
            iface.inventoryGrid.Pick(element)
            element.queue_free()


## Hide offered items pending host ACK so reject_trade can restore them.
func _execute_client_trade(iface: Node, traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    var pendingElements: Array[Node] = []
    for element: Node in iface.inventoryGrid.get_children():
        if element.selected:
            pendingElements.append(element)
            element.visible = false
            element.set_meta(&"trade_pending", true)
    CoopManager.worldState.set_meta(&"_pending_trade_elements", pendingElements)
    CoopManager.worldState.request_trade.rpc_id(1, traderPath, requestedIndices, offeredSlots)


## Client-side defer: hide inputs + stash rewards; host ACK triggers finalize_pending_task.
## Host path runs vanilla (trader save) then broadcasts to peers.
func _on_complete(data: Resource) -> void:
    var iface: Node = _lib._caller
    if iface == null:
        return
    if !CoopManager.is_session_active():
        return  # vanilla Complete runs.
    if CoopManager.isHost:
        # Vanilla still runs (no skip_super); broadcast after it via deferred.
        _broadcast_host_complete.call_deferred(iface, data)
        return
    if !(data is TaskData):
        return  # vanilla runs.
    if !is_instance_valid(iface.inputTarget) || !is_instance_valid(iface.trader):
        return  # vanilla runs.
    _lib.skip_super()

    var taskName: String = iface.inputTarget.taskData.name
    var pending: Dictionary = _pendingTasks.get(iface, {})
    if pending.has(taskName):
        CoopManager._log("[interface] Complete task=%s already_pending" % taskName)
        return
    CoopManager._log("[interface] Complete task=%s client_defer" % taskName)

    var selected: Array[Node] = []
    for child: Node in iface.inventoryGrid.get_children():
        if child.selected:
            child.visible = false
            child.set_meta(&"task_pending", true)
            selected.append(child)

    pending[taskName] = {
        &"selected": selected,
        &"taskData": iface.inputTarget.taskData,
    }
    _pendingTasks[iface] = pending

    var scene: Node = iface.get_tree().current_scene
    if is_instance_valid(scene):
        CoopManager.worldState.request_trader_task_complete.rpc_id(1, scene.get_path_to(iface.trader), taskName)
    iface.ResetInput()


func _broadcast_host_complete(iface: Node, data: Resource) -> void:
    if !is_instance_valid(iface) || !(data is TaskData) || !is_instance_valid(iface.trader):
        return
    var scene: Node = iface.get_tree().current_scene
    if !is_instance_valid(scene):
        return
    CoopManager.worldState.sync_trader_task_complete.rpc(scene.get_path_to(iface.trader), data.name)


## Host ACK path: destroy hidden inputs and spawn rewards (mirrors vanilla Complete).
func finalize_pending_task(iface: Node, taskName: String) -> void:
    var pending: Dictionary = _pendingTasks.get(iface, {})
    if !pending.has(taskName):
        CoopManager._log("[interface] finalize_pending_task task=%s NOT_FOUND" % taskName)
        return
    var bundle: Dictionary = pending[taskName]
    pending.erase(taskName)
    _pendingTasks[iface] = pending
    CoopManager._log("[interface] finalize_pending_task task=%s rewards=%d" % [taskName, bundle.taskData.receive.size() if bundle.taskData != null else 0])

    for element: Node in bundle.selected:
        if is_instance_valid(element):
            iface.inventoryGrid.Pick(element)
            element.queue_free()

    var taskData: TaskData = bundle.taskData
    for itemData: Resource in taskData.receive:
        var newSlotData: SlotData = SlotData.new()
        newSlotData.itemData = itemData
        if itemData.defaultAmount != 0 && itemData.subtype != "Magazine":
            newSlotData.amount = itemData.defaultAmount

        if itemData.type == "Furniture":
            iface.Create(newSlotData, iface.catalogGrid, false)
            Loader.Message("New Furniture Added [Catalog]", Color.GREEN)
        else:
            if !iface.AutoStack(newSlotData, iface.inventoryGrid):
                iface.Create(newSlotData, iface.inventoryGrid, true)

    iface.UpdateTraderInfo()


## Host reject path: restore hidden inventory so client keeps inputs.
func reject_pending_task(iface: Node, taskName: String) -> void:
    var pending: Dictionary = _pendingTasks.get(iface, {})
    if !pending.has(taskName):
        CoopManager._log("[interface] reject_pending_task task=%s NOT_FOUND" % taskName)
        return
    var bundle: Dictionary = pending[taskName]
    pending.erase(taskName)
    _pendingTasks[iface] = pending
    CoopManager._log("[interface] reject_pending_task task=%s restoring=%d" % [taskName, bundle.selected.size()])

    for element: Node in bundle.selected:
        if is_instance_valid(element):
            element.visible = true
            element.remove_meta(&"task_pending")

    Loader.Message("Task rejected by host", Color.RED)
    iface.PlayError()
