## Deterministic layout picker — replaces layouts_patch take_over_path.
##
## Vanilla Layouts._ready runs `randi_range(0, child_count - 1)` to pick one
## layout and frees the rest. In co-op, each peer runs this locally with its
## own RNG state, so layouts desync. Instead of patching Layouts.gd, we hook
## SceneTree.node_added: when a Layouts node enters the tree, we pick a
## deterministic child by path hash and remove the rest SYNCHRONOUSLY before
## its _ready fires. Vanilla _ready then sees child_count == 1 and its
## randi_range(0, 0) is a no-op identity pick.
##
## Non-coop: handler short-circuits, vanilla random pick stands.
extends RefCounted


const LAYOUTS_SCRIPT_PATH: String = "res://Scripts/Layouts.gd"


func connect_tree() -> void:
    var tree: SceneTree = CoopManager.get_tree()
    if tree != null && !tree.node_added.is_connected(_on_node_added):
        tree.node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
    if !CoopManager.is_session_active():
        return
    var script: Script = n.get_script()
    if script == null:
        return
    if script.resource_path != LAYOUTS_SCRIPT_PATH:
        return
    var count: int = n.get_child_count()
    if count <= 1:
        return
    var pick: int = absi(n.get_path().hash()) % count
    var chosen: Node = n.get_child(pick)
    for child: Node in n.get_children():
        if child != chosen:
            n.remove_child(child)
            child.queue_free()
