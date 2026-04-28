## Hook callbacks for LootSimulation.gd — host-authoritative loot; clients suppress generation.
## Replaces patches/loot_simulation_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("lootsimulation-_ready", _on_ready)
    lib.hook("lootsimulation-_ready-post", _apply_loot_multiplier)


func _on_ready() -> void:
    var sim: Node = _lib._caller
    if sim == null:
        return
    if !CoopManager.is_session_active():
        # Vanilla _ready runs after replace returns; multiplier applied via post hook.
        return
    if CoopManager.isHost:
        var scenePath: String = sim.get_tree().current_scene.scene_file_path if is_instance_valid(sim.get_tree().current_scene) else ""
        if !scenePath.is_empty() && scenePath in CoopManager.headlessMaps:
            _lib.skip_super()
            if sim.get_child_count() > 0:
                sim.get_child(0).queue_free()
            return
        # Vanilla runs (no skip_super); post hook applies multiplier.
        return
    # Client: skip vanilla generation.
    _lib.skip_super()
    if sim.get_child_count() > 0:
        sim.get_child(0).queue_free()


func _apply_loot_multiplier() -> void:
    var sim: Node = _lib._caller
    if sim == null:
        return
    # Skip when vanilla didn't run (client / headless handoff).
    if CoopManager.is_session_active() && !CoopManager.isHost:
        return
    var mul: float = CoopManager.settings.get("loot_multiplier", 1.0)
    if abs(mul - 1.0) < 0.001:
        return
    var originals: Array[Node] = []
    for child: Node in sim.get_children():
        originals.append(child)
    CoopManager._log("[loot_sim] apply_multiplier mul=%.2f originals=%d" % [mul, originals.size()])
    var delta: int = 0
    if mul > 1.0:
        var extraRatio: float = mul - 1.0
        for pickup: Node in originals:
            if !is_instance_valid(pickup):
                continue
            var whole: int = int(extraRatio)
            var frac: float = extraRatio - whole
            var copies: int = whole + (1 if randf() < frac else 0)
            for i: int in copies:
                _duplicate_pickup(sim, pickup)
                delta += 1
    else:
        var removeChance: float = 1.0 - mul
        for pickup: Node in originals:
            if !is_instance_valid(pickup):
                continue
            if randf() < removeChance:
                pickup.queue_free()
                delta -= 1
    CoopManager._log("[loot_sim] apply_multiplier done delta=%+d" % delta)


func _duplicate_pickup(sim: Node, source: Node) -> void:
    var itemData: Variant = source.get(&"slotData")
    if itemData == null:
        return
    var file: Variant = Database.get(itemData.itemData.file) if itemData.itemData != null else null
    if file == null:
        return
    var clone: Node3D = file.instantiate()
    sim.add_child(clone)
    var srcPos: Vector3 = source.global_position
    clone.global_position = srcPos + Vector3(randf_range(-0.3, 0.3), randf_range(0, 0.3), randf_range(-0.3, 0.3))
    if clone.has_method(&"Unfreeze"):
        clone.Unfreeze()
    clone.slotData = itemData
