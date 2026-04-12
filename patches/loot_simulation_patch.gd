## Patch for [code]LootSimulation.gd[/code] — host-authoritative loot generation.
## On host: generates loot normally (super._ready). Items are registered and
## broadcast by [code]world_state.register_scene_items()[/code] after scene change.
## On client: suppresses generation entirely. Items arrive from host via RPC.
extends "res://Scripts/LootSimulation.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    # _cm may already be set by inject_manager, but LootSimulation._ready() needs it
    # before inject_manager runs, so also try direct lookup as fallback
    if _cm == null:
        _cm = get_node_or_null("/root/CoopManager")
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
