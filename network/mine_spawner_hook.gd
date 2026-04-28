## Host-authoritative Mines spawning — replaces RNG-desynced per-peer Spawner runs.
##
## Vanilla Spawner.gd (attached to Map/Content/Spawners/Mines) calls
## ExecuteGenerate in _ready, which uses randf() for placement. Each peer's RNG
## state diverges, so mines spawn at different positions on host vs client.
##
## Approach:
## - SceneTree.node_added fires synchronously BEFORE _ready (see layouts_hook).
## - On client, we null the spawner's `data` before its _ready runs; vanilla
##   ExecuteGenerate then short-circuits ("Data not assigned!"). Empty Mines
##   node, ready to receive host's layout.
## - On host, vanilla ExecuteGenerate runs normally; we defer one frame to let
##   children populate, then capture (scene_file_path, transform) per mine and
##   broadcast.
## - Late-joiners request the cached layout from host on their own Mines
##   node_added.
extends RefCounted



# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")

const SPAWNER_SCRIPT_PATH: String = "res://Scripts/Spawner.gd"
const MINES_NODE_NAME: StringName = &"Mines"


var _minesNode: Node3D = null


func connect_tree() -> void:
    var tree: SceneTree = CoopManager.get_tree()
    if tree != null && !tree.node_added.is_connected(_on_node_added):
        tree.node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
    if !CoopManager.is_session_active():
        return
    if n.name != MINES_NODE_NAME:
        return
    var script: Script = n.get_script()
    if script == null || script.resource_path != SPAWNER_SCRIPT_PATH:
        return
    _minesNode = n as Node3D
    if !CoopManager.isHost:
        # Nulling data makes ExecuteGenerate hit `if !data: return`. Empty Mines node.
        n.set(&"data", null)
        CoopManager._log("[mines] client suppressed Spawner; requesting layout from host")
        CoopManager.worldState.request_mine_layout.rpc_id(1)
        return
    # Host: vanilla _ready fires next; defer capture so children are populated.
    _capture_and_broadcast.call_deferred()


func _capture_and_broadcast() -> void:
    if !is_instance_valid(_minesNode):
        return
    var layout: Array = []
    for child: Node in _minesNode.get_children():
        if !is_instance_valid(child) || child.scene_file_path.is_empty():
            continue
        layout.append({
            &"scene": child.scene_file_path,
            &"transform": (child as Node3D).global_transform,
        })
    CoopManager.worldState.lastMineLayout = layout
    CoopManager._log("[mines] host captured layout: %d mines" % layout.size())
    if layout.size() > 0:
        CoopManager.worldState.broadcast_mine_layout.rpc(layout)


func apply_layout(layout: Array) -> void:
    if !is_instance_valid(_minesNode):
        CoopManager._log("[mines] apply_layout: Mines not yet in tree, deferring one frame")
        await CoopManager.get_tree().process_frame
        if !is_instance_valid(_minesNode):
            CoopManager._log("[mines] apply_layout: still no Mines node, dropping (%d entries)" % layout.size())
            return
    # Defensive clear (data was nulled but Spawner could have spawned via manual generate flag).
    for child: Node in _minesNode.get_children():
        child.queue_free()
    var added: int = 0
    for entry: Dictionary in layout:
        var scenePath: String = entry.get(&"scene", "")
        var xform: Transform3D = entry.get(&"transform", Transform3D.IDENTITY)
        if scenePath.is_empty():
            continue
        var packed: PackedScene = load(scenePath)
        if packed == null:
            continue
        var inst: Node = packed.instantiate()
        _minesNode.add_child(inst, true)
        if inst is Node3D:
            (inst as Node3D).global_transform = xform
        added += 1
    CoopManager._log("[mines] client applied layout: %d mines" % added)
