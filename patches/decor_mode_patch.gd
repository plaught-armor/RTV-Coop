## Patch for DecorMode.gd — null-guards child.indicator access; vanilla crashes when Indicator freed.
extends "res://Scripts/DecorMode.gd"


func FurnitureVisibility(visibility: bool) -> void:
    var furnitures: Array = get_tree().get_nodes_in_group(&"Furniture")
    var transitions: Array = get_tree().get_nodes_in_group(&"Transition")

    for furniture: Node in furnitures:
        if !is_instance_valid(furniture) || !is_instance_valid(furniture.owner):
            continue
        for child: Node in furniture.owner.get_children():
            # take_over_path breaks `is Furniture`; duck-type via get() instead.
            var indicator: Variant = child.get(&"indicator")
            if indicator == null or not is_instance_valid(indicator):
                continue
            if visibility:
                indicator.show()
            else:
                indicator.hide()

    for transition: Node in transitions:
        if !is_instance_valid(transition) || !is_instance_valid(transition.owner):
            continue
        if transition.owner.spawn:
            if visibility:
                transition.owner.spawn.show()
            else:
                transition.owner.spawn.hide()
