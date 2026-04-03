## Patch for [code]Transition.gd[/code] — enforces host-only map transitions in co-op.
## Clients request the host to trigger the transition, preventing unilateral scene changes.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Transition.gd"

var _cm: Node


func _get_cm() -> Node:
    if _cm == null:
        _cm = get_node("/root/CoopManager")
    return _cm


func Interact():
    if !_get_cm().is_session_active():
        super.Interact()
        return

    if _get_cm().isHost:
        # Broadcast to clients first, then defer own transition by one frame
        # so ENet has time to flush the reliable RPC before scene changes.
        var transitionPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.sync_transition.rpc(transitionPath)
        host_transition_deferred.call_deferred()
    else:
        var transitionPath: String = get_tree().current_scene.get_path_to(self)
        _get_cm().worldState.request_transition.rpc_id(1, transitionPath)


func host_transition_deferred() -> void:
    super.Interact()
