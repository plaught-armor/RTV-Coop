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


## Client requests the host to interact with a door.
@rpc("any_peer", "call_remote", "reliable")
func RequestDoorInteract(doorPath: String) -> void:
	if !CoopManager.isHost:
		return
	if !IsValidInteractablePath(doorPath, &"Door"):
		return
	var door: Node = get_tree().current_scene.get_node(doorPath)
	# Run the patched Interact() which handles host logic + broadcast
	door.Interact()


## Host broadcasts a door's state to peers. Clients animate accordingly.
@rpc("authority", "call_remote", "reliable")
func SyncDoorState(doorPath: String, isOpen: bool) -> void:
	var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
	if door == null || !(door is Door):
		return
	door.isOpen = isOpen
	door.animationTime += 4.0
	door.handleMoving = true
	door.handleTarget = Vector3(0, 0, -45) if door.openAngle.y > 0.0 else Vector3(0, 0, 45)
	door.PlayDoor()


## Host broadcasts a door unlock to peers.
@rpc("authority", "call_remote", "reliable")
func SyncDoorUnlock(doorPath: String) -> void:
	var door: Node = get_tree().current_scene.get_node_or_null(doorPath)
	if door == null || !(door is Door):
		return
	door.locked = false
	door.PlayUnlock()

# ---------- Switch Sync ----------


## Client requests the host to interact with a switch.
@rpc("any_peer", "call_remote", "reliable")
func RequestSwitchInteract(switchPath: String) -> void:
	if !CoopManager.isHost:
		return
	if !IsValidInteractablePath(switchPath, &"Switch"):
		return
	var sw: Node = get_tree().current_scene.get_node(switchPath)
	# Toggle on host and broadcast
	sw.active = !sw.active
	if sw.active:
		sw.Activate()
		sw.PlaySwitch()
	else:
		sw.Deactivate()
		sw.PlaySwitch()
	SyncSwitchState.rpc(switchPath, sw.active)


## Host broadcasts a switch state to peers.
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
func SyncSimulation(syncTime: float, syncDay: int, syncWeather: String) -> void:
	Simulation.time = syncTime
	Simulation.day = syncDay
	Simulation.weather = syncWeather


## Reliable simulation sync for initial state on peer join.
@rpc("authority", "call_remote", "reliable")
func SyncSimulationReliable(syncTime: float, syncDay: int, syncWeather: String) -> void:
	Simulation.time = syncTime
	Simulation.day = syncDay
	Simulation.weather = syncWeather

# ---------- Full State Sync (on peer join) ----------


## Sends the current world state to a specific peer (called by host on peer connect).
func SendFullState(peerId: int) -> void:
	if !CoopManager.isHost:
		return

	# Sync all doors via Interactable group
	for node: Node in get_tree().get_nodes_in_group("Interactable"):
		var obj: Node = node.owner
		if obj is Door:
			var doorPath: String = get_tree().current_scene.get_path_to(obj)
			SyncDoorState.rpc_id(peerId, doorPath, obj.isOpen)
			if !obj.locked && obj.key:
				SyncDoorUnlock.rpc_id(peerId, doorPath)

	# Sync all switches
	for node: Node in get_tree().get_nodes_in_group("Switch"):
		var obj: Node = node.owner
		var switchPath: String = get_tree().current_scene.get_path_to(obj)
		SyncSwitchState.rpc_id(peerId, switchPath, obj.active)

	# Sync simulation (reliable for initial join)
	SyncSimulationReliable.rpc_id(peerId, Simulation.time, Simulation.day, Simulation.weather)

# ---------- Validation ----------


## Validates a NodePath is safe and points to the expected group.
func IsValidInteractablePath(nodePath: String, expectedGroup: StringName) -> bool:
	if ".." in nodePath:
		return false
	var node: Node = get_tree().current_scene.get_node_or_null(nodePath)
	if node == null:
		return false
	return node.is_in_group(expectedGroup)
