## Patch for [code]Mine.gd[/code] — co-op detonation sync.
##
## Overrides:
## [br]- [method Detonate]: host broadcasts detonation to all clients
## [br]- [method InstantDetonate]: host broadcasts instant detonation to all clients
##
## Mine detonation is host-authoritative. Clients receive detonation events
## and play the VFX/physics locally. Original behaviour preserved when not
## in a co-op session.
extends "res://Scripts/Mine.gd"

var _cm: Node


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


func Detonate() -> void:
	_ensure_cm()
	if is_instance_valid(_cm) && _cm.is_session_active() && _cm.isHost:
		var minePath: String = str(get_path())
		_cm.worldState.broadcast_mine_detonate(minePath, false)
	super.Detonate()


func InstantDetonate() -> void:
	_ensure_cm()
	if is_instance_valid(_cm) && _cm.is_session_active() && _cm.isHost:
		var minePath: String = str(get_path())
		_cm.worldState.broadcast_mine_detonate(minePath, true)
	super.InstantDetonate()
