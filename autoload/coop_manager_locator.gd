## Shared locator for CoopManager. Addresses Metro Mod Loader's autoload
## path divergence (/root/CoopManager vs /root/RTVModLoader/CoopManager) by
## discriminating via `has_meta(&"is_coop_manager")` set in CoopManager._ready.
## Preload this in patches and call [method find] instead of duplicating the walk.
extends RefCounted


static func find(tree: SceneTree) -> Node:
    if tree == null:
        return null
    var root: Node = tree.root
    if root == null:
        return null
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            return child
    return null
