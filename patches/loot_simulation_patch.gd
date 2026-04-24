## Patch for LootSimulation.gd — host-authoritative loot; clients suppress generation and receive via RPC.
extends "res://Scripts/LootSimulation.gd"

const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func _ready() -> void:
    if !_ensure_cm() || !_cm.is_session_active():
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
