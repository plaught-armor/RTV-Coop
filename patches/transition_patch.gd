## Patch for [code]Transition.gd[/code] — enforces host-only map transitions in co-op.
## Clients request the host to trigger the transition, preventing unilateral scene changes.
## In single-player, falls through to the original [method Interact].
extends "res://Scripts/Transition.gd"

func Interact():
    if !CoopManager.IsConnected():
        super.Interact()
        return

    if CoopManager.isHost:
        super.Interact()
    else:
        # Client requests the host to trigger this transition
        var transitionPath: String = get_tree().current_scene.get_path_to(self)
        CoopManager.worldState.RequestTransition.rpc_id(1, transitionPath)
