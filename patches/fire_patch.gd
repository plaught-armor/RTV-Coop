## Patch for [code]Fire.gd[/code] — co-op campfire state sync.
##
## Overrides:
## [br]- [method Interact]: broadcasts fire ignite/extinguish to all peers
##
## Fire state is host-authoritative. Clients request interaction, host
## processes and broadcasts the result. Original behaviour preserved
## when not in a co-op session.
extends "res://Scripts/Fire.gd"

var _cm: Node
## Cached scene-relative path to this campfire. Stable for the node's lifetime
## in the scene; mirrors the pattern used in door/switch/loot_container patches.
## Scene-relative keeps validation consistent with is_valid_path (which rejects
## absolute paths) and lets the receiver resolve via _scene_node().
var _cachedPath: String = ""


func _ready() -> void:
	super._ready()
	_cachedPath = get_tree().current_scene.get_path_to(self)


func _ensure_cm() -> void:
	if is_instance_valid(_cm):
		return
	var root: Node = get_tree().root if get_tree() != null else null
	if root == null:
		return
	for child: Node in root.get_children():
		if child.has_meta(&"is_coop_manager"):
			_cm = child
			return


func Interact() -> void:
	_ensure_cm()
	if !is_instance_valid(_cm) || !_cm.is_session_active():
		super.Interact()
		return

	if _cm.isHost:
		super.Interact()
		_cm.worldState.broadcast_fire_state(_cachedPath, active)
	else:
		_cm.worldState.request_fire_interact.rpc_id(1, _cachedPath)
