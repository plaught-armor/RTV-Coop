## Patch for LootSimulation.gd — host-authoritative loot; clients suppress generation and receive via RPC.
extends "res://Scripts/LootSimulation.gd"




func _ready() -> void:
    if !CoopManager.is_session_active():
        super._ready()
        return

    if CoopManager.isHost:
        # Skip generation when headless already ran: handoff spawns existing items.
        var scenePath: String = get_tree().current_scene.scene_file_path if is_instance_valid(get_tree().current_scene) else ""
        if !scenePath.is_empty() && scenePath in CoopManager.headlessMaps:
            if get_child_count() > 0:
                get_child(0).queue_free()
            return
        super._ready()
    else:
        if get_child_count() > 0:
            get_child(0).queue_free()
