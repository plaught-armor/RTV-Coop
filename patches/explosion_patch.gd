## Patch for [code]Explosion.gd[/code] — co-op awareness for grenade splash damage.
##
## Overrides:
## [br]- [method Explode]: adds co-op hit layer to explosion area mask
## [br]- [method CheckOverlap]: also detects remote player bodies
## [br]- [method CheckLOS]: recognizes "CoopRemote" group and routes damage via RPC.
##   Player damage is host-only during co-op to prevent double-damage from local
##   explosion + host RPC.
##
## Original behaviour is 100% preserved when not in a co-op session.
extends "res://Scripts/Explosion.gd"

var _cm: Node
const COOP_HIT_LAYER: int = 1 << 19


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


func Explode() -> void:
	_ensure_cm()
	if is_instance_valid(_cm) && _cm.is_session_active():
		area.collision_mask |= COOP_HIT_LAYER
	super.Explode()


func CheckOverlap() -> void:
	_ensure_cm()
	if !is_instance_valid(_cm) || !_cm.is_session_active():
		super.CheckOverlap()
		return

	var bodies: Array[Node3D] = area.get_overlapping_bodies()
	if bodies.size() == 0:
		return

	for target: Node3D in bodies:
		if target.is_in_group(&"CoopRemote"):
			_check_los_remote(target)
		elif target.get(&"head") != null:
			CheckLOS(target)


func CheckLOS(target) -> void:
	_ensure_cm()
	if !is_instance_valid(_cm) || !_cm.is_session_active():
		super.CheckLOS(target)
		return

	LOS.look_at(target.head.global_position, Vector3.UP, true)
	LOS.force_raycast_update()

	if !LOS.is_colliding():
		return

	var collider: Node = LOS.get_collider()

	if collider.is_in_group(&"AI"):
		target.ExplosionDamage(LOS.global_basis.z)

	# Host-only: prevents double damage on clients (local explosion + host RPC)
	if collider.is_in_group(&"Player") && _cm.isHost:
		target.get_child(0).ExplosionDamage()


## LOS check for remote players. Host only — sends damage via RPC.
func _check_los_remote(target: Node3D) -> void:
	if !_cm.isHost:
		return

	var eyePos: Vector3 = target.global_position + Vector3(0, 1.6, 0)
	LOS.look_at(eyePos, Vector3.UP, true)
	LOS.force_raycast_update()

	if !LOS.is_colliding():
		return

	var collider: Node = LOS.get_collider()
	if collider.is_in_group(&"CoopRemote"):
		var remoteRoot: Node3D = _find_remote_root(collider)
		if remoteRoot != null:
			var peerId: int = remoteRoot.get_meta(&"peer_id", -1)
			if peerId > 0:
				_cm.aiState.send_explosion_damage_to_peer(peerId)


func _find_remote_root(node: Node) -> Node3D:
	var current: Node = node
	while current != null && is_instance_valid(current):
		if current.is_in_group(&"CoopRemote"):
			if current.has_meta(&"peer_id"):
				return current as Node3D
		current = current.get_parent()
	return null
