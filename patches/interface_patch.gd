## Patch for Interface.gd — broadcasts drops; defers client task completion until host ACK.
extends "res://Scripts/Interface.gd"

const PATH_MAP: NodePath = ^"/root/Map"


# Pending task completions awaiting host ACK, keyed by task name:
# { selected: Array[Node], taskData: TaskData }.
var _pendingTasks: Dictionary = {}


func Drop(target: Node) -> void:
    if !CoopManager.is_session_active():
        super.Drop(target)
        return

    var map: Node = get_tree().current_scene.get_node(PATH_MAP)
    var file: PackedScene = Database.get(target.slotData.itemData.file)

    if !file:
        CoopManager._log("File not found: " + target.slotData.itemData.name)
        target.queue_free()
        PlayDrop()
        return

    var transform: Dictionary = _resolve_drop_transform()
    var dropForce: float = 2.5

    if target.slotData.itemData.stackable:
        _spawn_stackable_drops(file, target, map, transform, dropForce)
    else:
        _spawn_single_drop(file, target, map, transform, dropForce)

    target.reparent(self)
    target.queue_free()
    PlayDrop()
    UpdateStats(true)


func _resolve_drop_transform() -> Dictionary:
    var dir: Vector3 = Vector3.ZERO
    var pos: Vector3 = Vector3.ZERO
    var rot: Vector3 = Vector3.ZERO

    if is_instance_valid(trader) && hoverGrid == null:
        dir = trader.global_transform.basis.z
        pos = (trader.global_position + Vector3(0, 1.0, 0)) + dir / 2
        rot = Vector3(-25, trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif !is_instance_valid(trader) && (hoverGrid == null || hoverGrid.get_parent().name == "Inventory"):
        dir = -camera.global_transform.basis.z
        pos = (camera.global_position + Vector3(0, -0.25, 0)) + dir / 2
        rot = Vector3(-25, camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif !is_instance_valid(trader) && hoverGrid.get_parent().name == "Container":
        dir = container.global_transform.basis.z
        pos = (container.global_position + Vector3(0, 0.5, 0)) + dir / 2
        rot = Vector3(-25, container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)

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


func CompleteDeal() -> void:
    if !CoopManager.is_session_active():
        super.CompleteDeal()
        return
    if !is_instance_valid(trader):
        return

    var requestedIndices: PackedInt32Array = _collect_requested_supply_indices()
    var offeredSlots: Array[Dictionary] = _collect_offered_inventory_slots()

    if requestedIndices.is_empty():
        return

    var traderPath: String = get_tree().current_scene.get_path_to(trader)
    if CoopManager.isHost:
        _execute_host_trade(traderPath, requestedIndices, offeredSlots)
    else:
        _execute_client_trade(traderPath, requestedIndices, offeredSlots)


func _collect_requested_supply_indices() -> PackedInt32Array:
    var out: PackedInt32Array = []
    var supplyChildren: Array[Node] = supplyGrid.get_children()
    for i: int in supplyChildren.size():
        if supplyChildren[i].selected:
            out.append(i)
    return out


func _collect_offered_inventory_slots() -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    for element: Node in inventoryGrid.get_children():
        if element.selected:
            out.append(CoopManager.slotSerializer.pack(element.slotData))
    return out


func _execute_host_trade(traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    CoopManager.worldState.request_trade(traderPath, requestedIndices, offeredSlots)
    for element: Node in inventoryGrid.get_children():
        if element.selected:
            inventoryGrid.Pick(element)
            element.queue_free()


## Hide offered items pending host ACK so reject_trade can restore them.
func _execute_client_trade(traderPath: String, requestedIndices: PackedInt32Array, offeredSlots: Array[Dictionary]) -> void:
    var pendingElements: Array[Node] = []
    for element: Node in inventoryGrid.get_children():
        if element.selected:
            pendingElements.append(element)
            element.visible = false
            element.set_meta(&"trade_pending", true)
    CoopManager.worldState.set_meta(&"_pending_trade_elements", pendingElements)
    CoopManager.worldState.request_trade.rpc_id(1, traderPath, requestedIndices, offeredSlots)


## Client-side defer: hide inputs + stash rewards; host ACK triggers finalize_pending_task.
## Host path runs super (vanilla trader save) then broadcasts to peers.
func Complete(data: Resource) -> void:
    if !CoopManager.is_session_active():
        super.Complete(data)
        return
    if CoopManager.isHost:
        super.Complete(data)
        if data is TaskData && is_instance_valid(trader):
            var scene: Node = get_tree().current_scene
            if is_instance_valid(scene):
                CoopManager.worldState.sync_trader_task_complete.rpc(scene.get_path_to(trader), data.name)
        return
    if !(data is TaskData):
        super.Complete(data)
        return
    if !is_instance_valid(inputTarget) || !is_instance_valid(trader):
        super.Complete(data)
        return

    var taskName: String = inputTarget.taskData.name
    if _pendingTasks.has(taskName):
        return

    var selected: Array[Node] = []
    for child: Node in inventoryGrid.get_children():
        if child.selected:
            child.visible = false
            child.set_meta(&"task_pending", true)
            selected.append(child)

    _pendingTasks[taskName] = {
        &"selected": selected,
        &"taskData": inputTarget.taskData,
    }

    var scene: Node = get_tree().current_scene
    if is_instance_valid(scene):
        CoopManager.worldState.request_trader_task_complete.rpc_id(1, scene.get_path_to(trader), taskName)
    ResetInput()


## Host ACK path: destroy hidden inputs and spawn rewards (mirrors vanilla Complete).
func finalize_pending_task(taskName: String) -> void:
    if !_pendingTasks.has(taskName):
        return
    var bundle: Dictionary = _pendingTasks[taskName]
    _pendingTasks.erase(taskName)

    for element: Node in bundle.selected:
        if is_instance_valid(element):
            inventoryGrid.Pick(element)
            element.queue_free()

    var taskData: TaskData = bundle.taskData
    for itemData: Resource in taskData.receive:
        var newSlotData: SlotData = SlotData.new()
        newSlotData.itemData = itemData
        if itemData.defaultAmount != 0 && itemData.subtype != "Magazine":
            newSlotData.amount = itemData.defaultAmount

        if itemData.type == "Furniture":
            Create(newSlotData, catalogGrid, false)
            Loader.Message("New Furniture Added [Catalog]", Color.GREEN)
        else:
            if !AutoStack(newSlotData, inventoryGrid):
                Create(newSlotData, inventoryGrid, true)

    UpdateTraderInfo()


## Host reject path: restore hidden inventory so client keeps inputs.
func reject_pending_task(taskName: String) -> void:
    if !_pendingTasks.has(taskName):
        return
    var bundle: Dictionary = _pendingTasks[taskName]
    _pendingTasks.erase(taskName)

    for element: Node in bundle.selected:
        if is_instance_valid(element):
            element.visible = true
            element.remove_meta(&"task_pending")

    Loader.Message("Task rejected by host", Color.RED)
    PlayError()
