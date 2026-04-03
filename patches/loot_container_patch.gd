## Patch for [code]LootContainer.gd[/code] — host-authoritative container interactions.
## Host generates and owns the loot array. Clients receive it via RPC.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/LootContainer.gd"

var _cm: Node


func _get_cm() -> Node:
    if _cm == null:
        _cm = get_node("/root/CoopManager")
    return _cm


const SlotSerializerScript = preload("res://mod/network/slot_serializer.gd")


func Interact():
    if !_get_cm().is_session_active():
        super.Interact()
        return

    if _get_cm().isHost:
        super.Interact()
        # After opening, broadcast the current loot state
        var containerPath: String = get_tree().current_scene.get_path_to(self)
        var packedLoot: Array = SlotSerializerScript.pack_array(loot)
        _get_cm().worldState.sync_container_state.rpc(containerPath, packedLoot)
    else:
        # Client requests to open the container
        var containerPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.request_container_open.rpc_id(1, containerPath)
