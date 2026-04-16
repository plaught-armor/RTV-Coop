## Patch for [code]Interface.gd[/code] — broadcasts dropped items for co-op sync.
## Reimplements [method Drop] with network broadcast after each pickup creation.
extends "res://Scripts/Interface.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func Drop(target: Node) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Drop(target)
        return

    var map: Node = get_tree().current_scene.get_node("/root/Map")
    var file: PackedScene = Database.get(target.slotData.itemData.file)

    if !file:
        _cm._log("File not found: " + target.slotData.itemData.name)
        target.queue_free()
        PlayDrop()
        return

    var dropDirection: Vector3 = Vector3.ZERO
    var dropPosition: Vector3 = Vector3.ZERO
    var dropRotation: Vector3 = Vector3.ZERO
    var dropForce: float = 2.5

    if is_instance_valid(trader):
        if hoverGrid == null:
            dropDirection = trader.global_transform.basis.z
            dropPosition = (trader.global_position + Vector3(0, 1.0, 0)) + dropDirection / 2
            dropRotation = Vector3(-25, trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    else:
        if hoverGrid == null:
            dropDirection = -camera.global_transform.basis.z
            dropPosition = (camera.global_position + Vector3(0, -0.25, 0)) + dropDirection / 2
            dropRotation = Vector3(-25, camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
        elif hoverGrid.get_parent().name == "Inventory":
            dropDirection = -camera.global_transform.basis.z
            dropPosition = (camera.global_position + Vector3(0, -0.25, 0)) + dropDirection / 2
            dropRotation = Vector3(-25, camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
        elif hoverGrid.get_parent().name == "Container":
            dropDirection = container.global_transform.basis.z
            dropPosition = (container.global_position + Vector3(0, 0.5, 0)) + dropDirection / 2
            dropRotation = Vector3(-25, container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)

    if target.slotData.itemData.stackable:
        var boxSize: int = target.slotData.itemData.defaultAmount
        var boxesNeeded: int = ceili(float(target.slotData.amount) / float(boxSize))
        var amountLeft: int = target.slotData.amount

        for i: int in range(boxesNeeded):
            var pickup: Node3D = file.instantiate()
            map.add_child(pickup)
            pickup.position = dropPosition
            pickup.rotation_degrees = dropRotation
            pickup.linear_velocity = dropDirection * dropForce
            pickup.Unfreeze()

            var newSlotData: SlotData = SlotData.new()
            newSlotData.itemData = target.slotData.itemData
            if amountLeft > boxSize:
                amountLeft -= boxSize
                newSlotData.amount = boxSize
                pickup.slotData.Update(newSlotData)
            else:
                newSlotData.amount = amountLeft
                pickup.slotData.Update(newSlotData)

            # --- CO-OP: broadcast this dropped item ---
            _cm.worldState.broadcast_item_drop(pickup)
    else:
        var pickup: Node3D = file.instantiate()
        map.add_child(pickup)
        pickup.position = dropPosition
        pickup.rotation_degrees = dropRotation
        pickup.linear_velocity = dropDirection * dropForce
        pickup.Unfreeze()
        pickup.slotData.Update(target.slotData)
        pickup.UpdateAttachments()

        # --- CO-OP: broadcast this dropped item ---
        _cm.worldState.broadcast_item_drop(pickup)

    target.reparent(self)
    target.queue_free()
    PlayDrop()
    UpdateStats(true)


func CompleteDeal() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.CompleteDeal()
        return
    if !is_instance_valid(trader):
        return

    # Collect requested supply indices.
    var requestedIndices: PackedInt32Array = []
    var supplyChildren: Array[Node] = supplyGrid.get_children()
    for i: int in supplyChildren.size():
        if supplyChildren[i].selected:
            requestedIndices.append(i)

    # Pack offered inventory items.
    var offeredSlots: Array[Dictionary] = []
    for element: Node in inventoryGrid.get_children():
        if element.selected:
            offeredSlots.append(_cm.SlotSerializerScript.pack(element.slotData))

    if requestedIndices.is_empty():
        return

    var traderPath: String = get_tree().current_scene.get_path_to(trader)

    if _cm.isHost:
        # Host executes via world_state directly.
        _cm.worldState.request_trade(traderPath, requestedIndices, offeredSlots)
        # Remove offered items locally (host is authoritative).
        for element: Node in inventoryGrid.get_children():
            if element.selected:
                inventoryGrid.Pick(element)
                element.queue_free()
    else:
        # Client: hide offered items visually but keep them until host ACKs.
        # Store packed data so reject_trade can restore them.
        var pendingElements: Array[Node] = []
        for element: Node in inventoryGrid.get_children():
            if element.selected:
                pendingElements.append(element)
                element.visible = false
                element.set_meta(&"trade_pending", true)
        _cm.worldState.set_meta(&"_pending_trade_elements", pendingElements)
        _cm.worldState.request_trade.rpc_id(1, traderPath, requestedIndices, offeredSlots)
