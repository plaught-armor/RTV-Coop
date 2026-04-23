## Patch for LootSimulation.gd — host-authoritative loot; clients suppress generation and receive via RPC.
extends "res://Scripts/LootSimulation.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    # LootSimulation._ready runs before inject_manager; lazy lookup is the fallback.
    if _cm == null:
        var root: Node = get_tree().root if get_tree() != null else null
        if root != null:
            for child: Node in root.get_children():
                if child.has_meta(&"is_coop_manager"):
                    _cm = child
                    break
    if _cm == null || !_cm.is_session_active():
        super._ready()
        return

    if _cm.isHost:
        # Skip generation when headless already ran: handoff spawns existing items.
        var scenePath: String = get_tree().current_scene.scene_file_path if is_instance_valid(get_tree().current_scene) else ""
        if !scenePath.is_empty() && scenePath in _cm.headlessMaps:
            if get_child_count() > 0:
                get_child(0).queue_free()
            return
        super._ready()
    else:
        if get_child_count() > 0:
            get_child(0).queue_free()
