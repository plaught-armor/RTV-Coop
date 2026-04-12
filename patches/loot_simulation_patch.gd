## Patch for [code]LootSimulation.gd[/code] — host-authoritative loot generation.
## On host: generates loot normally (super._ready). Items are registered and
## broadcast by [code]world_state.register_scene_items()[/code] after scene change.
## On client: suppresses generation entirely. Items arrive from host via RPC.
extends "res://Scripts/LootSimulation.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    # _cm may already be set by inject_manager, but LootSimulation._ready() runs
    # before inject_manager, so try lazy lookup as fallback.
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
        # Host generates items normally — register_scene_items() handles sync
        super._ready()
    else:
        # Client: free placeholder Label3D, skip loot generation
        if get_child_count() > 0:
            get_child(0).queue_free()
