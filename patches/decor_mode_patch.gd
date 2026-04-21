## Patch for [code]DecorMode.gd[/code] — null-guard the indicator access.
## Vanilla iterates Furniture-group nodes and reads [code]child.indicator[/code]
## without checking it exists, crashing on placed pieces whose Indicator was
## freed (or pieces whose Furniture script ran without _ready resolving the
## @onready var). Same logic, just defensive.
extends "res://Scripts/DecorMode.gd"


func FurnitureVisibility(visibility: bool) -> void:
    var furnitures: Array = get_tree().get_nodes_in_group(&"Furniture")
    var transitions: Array = get_tree().get_nodes_in_group(&"Transition")

    for furniture: Node in furnitures:
        if !is_instance_valid(furniture) || !is_instance_valid(furniture.owner):
            continue
        for child: Node in furniture.owner.get_children():
            # Duck-typed: take_over_path breaks `is Furniture` class check,
            # so probe `indicator` via get() — returns null for non-Furniture.
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
