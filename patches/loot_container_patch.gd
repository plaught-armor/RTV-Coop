## Patch for [code]LootContainer.gd[/code] — host-authoritative container interactions.
## Host generates and owns the loot array. Clients receive it via RPC.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/LootContainer.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()


func Interact():
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        super.Interact()
        return

    var containerPath: String = get_tree().current_scene.get_path_to(self)
    if _cm.isHost:
        super.Interact()
        var packedLoot: Array[Dictionary] = _cm.SlotSerializerScript.pack_array(loot)
        _cm.worldState.sync_container_state.rpc(containerPath, packedLoot)
    else:
        _cm.worldState.request_container_open.rpc_id(1, containerPath)
