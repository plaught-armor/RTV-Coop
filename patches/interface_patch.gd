## Patch for [code]Interface.gd[/code] — broadcasts dropped items for co-op sync.
## Reimplements [method Drop] with network broadcast after each pickup creation.
extends "res://Scripts/Interface.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func Drop(target):
    if _cm == null || !_cm.is_session_active():
        super.Drop(target)
        return

    var map = get_tree().current_scene.get_node("/root/Map")
    var file = Database.get(target.slotData.itemData.file)

    if !file:
        print("File not found: " + target.slotData.itemData.name)
        target.queue_free()
        PlayDrop()
        return

    var dropDirection
    var dropPosition
    var dropRotation
    var dropForce = 2.5

    if trader:
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
        var boxSize = target.slotData.itemData.defaultAmount
        var boxesNeeded = ceili(target.slotData.amount / boxSize)
        var amountLeft = target.slotData.amount

        for i: int in range(boxesNeeded):
            var pickup = file.instantiate()
            map.add_child(pickup)
            pickup.position = dropPosition
            pickup.rotation_degrees = dropRotation
            pickup.linear_velocity = dropDirection * dropForce
            pickup.Unfreeze()

            var newSlotData = SlotData.new()
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
        var pickup = file.instantiate()
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
