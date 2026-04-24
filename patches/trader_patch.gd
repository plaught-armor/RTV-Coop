## Patch for Trader.gd — host-authoritative task completion (client requests, host broadcasts).
extends "res://Scripts/Trader.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node



func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func CompleteTask(taskData: TaskData) -> void:
    if !_ensure_cm() || !_cm.is_session_active():
        super.CompleteTask(taskData)
        return
    
    var scene: Node = get_tree().current_scene
    if _cm.isHost:
        super.CompleteTask(taskData)
        if !is_instance_valid(scene):
            return
        _cm.worldState.sync_trader_task_complete.rpc(scene.get_path_to(self), taskData.name)
        return
    if !is_instance_valid(scene):
        return
    _cm.worldState.request_trader_task_complete.rpc_id(1, scene.get_path_to(self), taskData.name)


## Mirrors super.CompleteTask minus the save (host owns Traders.tres).
func apply_task_complete(taskName: String) -> void:
    if tasksCompleted.has(taskName):
        return
    tasksCompleted.append(taskName)
    if has_method(&"PlayTraderTask"):
        PlayTraderTask()
    Loader.Message("Task Completed: " + taskName, Color.GREEN)
