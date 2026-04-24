## Patch for LootSimulation.gd — host-authoritative loot; clients suppress generation and receive via RPC.
extends "res://Scripts/LootSimulation.gd"




func _ready() -> void:
    if !CoopManager.is_session_active():
        super._ready()
        _apply_loot_multiplier()
        return

    if CoopManager.isHost:
        # Skip generation when headless already ran: handoff spawns existing items.
        var scenePath: String = get_tree().current_scene.scene_file_path if is_instance_valid(get_tree().current_scene) else ""
        if !scenePath.is_empty() && scenePath in CoopManager.headlessMaps:
            if get_child_count() > 0:
                get_child(0).queue_free()
            return
        super._ready()
        _apply_loot_multiplier()
    else:
        if get_child_count() > 0:
            get_child(0).queue_free()


# Post-hoc scales the loot count. mul > 1.0 duplicates entries probabilistically;
# mul < 1.0 removes. No-op at 1.0. Runs after super's SpawnItems so all pickups
# are already children.
func _apply_loot_multiplier() -> void:
    var mul: float = CoopManager.settings.get("loot_multiplier", 1.0)
    if abs(mul - 1.0) < 0.001:
        return
    var originals: Array[Node] = []
    for child: Node in get_children():
        originals.append(child)
    if mul > 1.0:
        var extraRatio: float = mul - 1.0
        for pickup: Node in originals:
            if !is_instance_valid(pickup):
                continue
            var whole: int = int(extraRatio)
            var frac: float = extraRatio - whole
            var copies: int = whole + (1 if randf() < frac else 0)
            for i: int in copies:
                _duplicate_pickup(pickup)
    else:
        var removeChance: float = 1.0 - mul
        for pickup: Node in originals:
            if !is_instance_valid(pickup):
                continue
            if randf() < removeChance:
                pickup.queue_free()


func _duplicate_pickup(source: Node) -> void:
    var itemData: Variant = source.get(&"slotData")
    if itemData == null:
        return
    var file: Variant = Database.get(itemData.itemData.file) if itemData.itemData != null else null
    if file == null:
        return
    var clone: Node3D = file.instantiate()
    add_child(clone)
    var srcPos: Vector3 = source.global_position
    clone.global_position = srcPos + Vector3(randf_range(-0.3, 0.3), randf_range(0, 0.3), randf_range(-0.3, 0.3))
    if clone.has_method(&"Unfreeze"):
        clone.Unfreeze()
    clone.slotData = itemData
