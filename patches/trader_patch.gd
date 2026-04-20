## Patches [code]Trader.gd[/code] so task completions are host-authoritative.
##
## In solo, [method Trader.CompleteTask] appends to `tasksCompleted`,
## plays the cue and saves. In co-op every peer runs the same Interface UI
## locally, so both host and client would append the same task to their own
## `tasksCompleted`, and the client's save rides to the host on transition
## with a divergent list.
##
## Fix: client requests completion from host; host applies + broadcasts; all
## peers apply the same list under the same authority.
extends "res://Scripts/Trader.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


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
    # Client: stage completion through the host. Host's broadcast flips the
    # local state back via apply_task_complete().
    if !is_instance_valid(scene):
        return
    _cm.worldState.request_trader_task_complete.rpc_id(1, scene.get_path_to(self), taskData.name)


## Called from world_state when the host broadcasts a completion. Mirrors the
## super.CompleteTask side-effects except for the save (host is authoritative
## for the on-disk Traders.tres).
func apply_task_complete(taskName: String) -> void:
    if tasksCompleted.has(taskName):
        return
    tasksCompleted.append(taskName)
    if has_method(&"PlayTraderTask"):
        PlayTraderTask()
    Loader.Message("Task Completed: " + taskName, Color.GREEN)
