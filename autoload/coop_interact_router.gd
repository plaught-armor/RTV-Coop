## Routes Interactor-triggered events (Bed/Door/Container/Trader/Switch/Fire)
## to the appropriate worldState host method or client request RPC. Dispatch is
## keyed on the target script's resource path so it remains stable after
## [code]take_over_path[/code] swaps patches in — `is <PatchedClass>` checks
## are unreliable once class_name registry references a replaced resource
## (see cerebrum-donot 2026-04-20).
extends RefCounted


# scriptPath -> [ hostMethod, requestMethod ]
const ROUTES: Dictionary[String, Array] = {
    "res://Scripts/Bed.gd":           [&"host_bed_interact",       &"request_bed_interact"],
    "res://Scripts/Door.gd":          [&"host_door_interact",      &"request_door_interact"],
    "res://Scripts/LootContainer.gd": [&"host_container_interact", &"request_container_open"],
    "res://Scripts/Trader.gd":        [&"host_trader_interact",    &"request_trader_open"],
    "res://Scripts/Switch.gd":        [&"host_switch_interact",    &"request_switch_interact"],
    "res://Scripts/Fire.gd":          [&"host_fire_interact",      &"request_fire_interact"],
}


## Returns true if routed through co-op; false means caller should run target.Interact() locally.
func dispatch(cm: Node, target: Node) -> bool:
    if !is_instance_valid(target) || !cm.is_session_active():
        return false
    var tree: SceneTree = cm.get_tree()
    var scene: Node = tree.current_scene if tree != null else null
    if !is_instance_valid(scene):
        return false

    var scriptObj: Script = target.get_script()
    if scriptObj == null:
        return false
    var route: Array = ROUTES.get(scriptObj.resource_path, [])
    if route.is_empty():
        return false

    _route(cm, target, scene, route[0], route[1])
    return true


func _route(cm: Node, target: Node, scene: Node, hostMethod: StringName, requestMethod: StringName) -> void:
    if cm.isHost:
        cm.worldState.call(hostMethod, target)
    else:
        cm.worldState.rpc_id(1, requestMethod, scene.get_path_to(target))
