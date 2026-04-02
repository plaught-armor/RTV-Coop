## Patch for [code]Transition.gd[/code] — enforces host-only map transitions in co-op.
## Clients request the host to trigger the transition, preventing unilateral scene changes.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Transition.gd"

func Interact():
    if !CoopManager.IsConnected():
        super.Interact()
        return

    if CoopManager.isHost:
        # Broadcast to clients first, then defer own transition by one frame
        # so ENet has time to flush the reliable RPC before scene changes.
        var transitionPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.SyncTransition.rpc(transitionPath)
        HostTransitionDeferred.call_deferred()
    else:
        var transitionPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.RequestTransition.rpc_id(1, transitionPath)


func HostTransitionDeferred() -> void:
    super.Interact()
