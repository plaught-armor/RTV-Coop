## Patch for [code]Transition.gd[/code] — independent map transitions in co-op.
## Each player transitions on their own via [code]super.Interact()[/code].
## Map change is broadcast automatically by [code]coop_manager.on_scene_changed()[/code]
## via [code]sync_peer_map[/code] RPC. This patch exists as a hook point — the original
## Interact() handles saving, simulation updates, and scene loading correctly for each
## player independently.
extends "res://Scripts/Transition.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()
