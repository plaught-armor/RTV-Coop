## Handles world state synchronisation: doors, switches, simulation time/weather.
## Host is authoritative. Clients send interaction requests, host validates and broadcasts.
class_name WorldState
extends Node

const SIM_SYNC_INTERVAL: float = 2.0
var simSyncTimer: float = 0.0


func _physics_process(delta: float) -> void:
	if !CoopManager.isActive || !CoopManager.isHost:
		return

	simSyncTimer += delta
	if simSyncTimer < SIM_SYNC_INTERVAL:
		return
	simSyncTimer = 0.0

	SyncSimulation.rpc(Simulation.time, Simulation.day, Simulation.weather)

# ---------- Door Sync ----------


## Client requests the host to toggle a door.
@rpc("any_peer", "call_remote", "reliable")
func RequestDoorInteract(doorPath: String) -> void:
	if !CoopManager.isHost:
		return
	var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
	if door == null:
		return
	if !(door is Door):
		return
	if door.isOccupied:
		return
	if door.locked:
		return
	# Toggle on the host — this runs the original logic
	door.isOpen = !door.isOpen
	door.animationTime += 4.0
	door.handleMoving = true
	if door.openAngle.y > 0.0:
		door.handleTarget = Vector3(0, 0, -45)
	else:
		door.handleTarget = Vector3(0, 0, 45)
	door.PlayDoor()
	# Broadcast result to all peers
	SyncDoorState.rpc(doorPath, door.isOpen)


## Host broadcasts a door's open/close state to all peers.
@rpc("authority", "call_remote", "reliable")
func SyncDoorState(doorPath: String, isOpen: bool) -> void:
	var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
	if door == null || !(door is Door):
		return
	door.isOpen = isOpen
	door.animationTime += 4.0
	door.handleMoving = true
	if door.openAngle.y > 0.0:
		door.handleTarget = Vector3(0, 0, -45)
	else:
		door.handleTarget = Vector3(0, 0, 45)
	door.PlayDoor()


## Host broadcasts a door unlock to all peers.
@rpc("authority", "call_remote", "reliable")
func SyncDoorUnlock(doorPath: String) -> void:
	var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
	if door == null || !(door is Door):
		return
	door.locked = false
	door.PlayUnlock()

# ---------- Switch Sync ----------


## Client requests the host to toggle a switch.
@rpc("any_peer", "call_remote", "reliable")
func RequestSwitchInteract(switchPath: String) -> void:
	if !CoopManager.isHost:
		return
	var sw: Node = get_tree().current_scene.get_node_or_null(switchPath)
	if sw == null:
		return
	# Toggle on the host
	sw.Interact()
	# Broadcast
	SyncSwitchState.rpc(switchPath, sw.active)


## Host broadcasts a switch state to all peers.
@rpc("authority", "call_remote", "reliable")
func SyncSwitchState(switchPath: String, active: bool) -> void:
	var sw: Node = get_tree().current_scene.get_node_or_null(switchPath)
	if sw == null:
		return
	if active && !sw.active:
		sw.Activate()
		sw.PlaySwitch()
	elif !active && sw.active:
		sw.Deactivate()
		sw.PlaySwitch()

# ---------- Simulation Sync ----------


## Host periodically broadcasts time/day/weather to all peers (unreliable).
@rpc("authority", "call_remote", "unreliable")
func SyncSimulation(time: float, day: int, weather: String) -> void:
	Simulation.time = time
	Simulation.day = day
	Simulation.weather = weather

# ---------- Full State Sync (on peer join) ----------


## Sends the current world state to a specific peer (called by host on peer connect).
func SendFullState(peerId: int) -> void:
	if !CoopManager.isHost:
		return

	# Sync all doors
	for node: Node in get_tree().get_nodes_in_group("Interactable"):
		var owner: Node = node.owner
		if owner is Door:
			var doorPath: String = get_tree().current_scene.get_path_to(owner)
			SyncDoorState.rpc_id(peerId, doorPath, owner.isOpen)
			if !owner.locked && owner.key:
				SyncDoorUnlock.rpc_id(peerId, doorPath)

	# Sync all switches
	for node: Node in get_tree().get_nodes_in_group("Switch"):
		var owner: Node = node.owner
		var switchPath: String = get_tree().current_scene.get_path_to(owner)
		SyncSwitchState.rpc_id(peerId, switchPath, owner.active)

	# Sync simulation
	SyncSimulation.rpc_id(peerId, Simulation.time, Simulation.day, Simulation.weather)
