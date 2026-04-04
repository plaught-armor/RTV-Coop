## Patch for [code]Transition.gd[/code] — enforces host-only map transitions in co-op.
## Clients request the host to trigger the transition, preventing unilateral scene changes.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Transition.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()


func Interact():
    if _cm == null || !_cm.is_session_active():
        super.Interact()
        return

    var transitionPath: String = get_tree().current_scene.get_path_to(self)
    if _cm.isHost:
        _cm.worldState.sync_transition.rpc(transitionPath)
        host_transition_deferred.call_deferred()
    else:
        _cm.worldState.request_transition.rpc_id(1, transitionPath)


func host_transition_deferred() -> void:
    super.Interact()
