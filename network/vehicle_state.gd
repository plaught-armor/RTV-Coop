## Host-auth 10Hz transform sync for Helicopter/BTR/Police/CASA and rockets in flight.
extends Node

var TRACKED_SCRIPTS: PackedStringArray = [
    "res://Scripts/Helicopter.gd",
    "res://Scripts/BTR.gd",
    "res://Scripts/Police.gd",
    "res://Scripts/CASA.gd",
    "res://Scripts/RocketGrad.gd",
    "res://Scripts/RocketHelicopter.gd",
]

var _cm: Node
var _currentScene: Node = null

# relPath -> { pos, rot: Quaternion, turret: float }
var _snapshots: Dictionary = {}

# 120Hz / 12 = 10Hz; matches ai_state.gd cadence for consistent bandwidth profile.
const SEND_EVERY_N_TICKS: int = 12


func init_manager(manager: Node) -> void:
    _cm = manager


func refresh_scene_cache() -> void:
    _currentScene = get_tree().current_scene
    _snapshots.clear()


func _physics_process(_delta: float) -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active() || !_cm.isHost:
        return
    if Engine.get_physics_frames() % SEND_EVERY_N_TICKS != 0:
        return
    if !is_instance_valid(_currentScene):
        return
    _broadcast_vehicle_snapshots()


func _broadcast_vehicle_snapshots() -> void:
    for vehicle: Node3D in _collect_vehicles(_currentScene):
        var relPath: String = String(_currentScene.get_path_to(vehicle))
        var rotQuat: Quaternion = vehicle.global_transform.basis.get_rotation_quaternion()
        var turretRot: float = 0.0
        var tower: Node = vehicle.get_node_or_null(^"Chassis/Tower")
        if is_instance_valid(tower) && tower is Node3D:
            turretRot = (tower as Node3D).rotation.y
        sync_vehicle_snapshot.rpc(relPath, vehicle.global_transform.origin, rotQuat, turretRot)


func _collect_vehicles(root: Node) -> Array[Node3D]:
    var out: Array[Node3D] = []
    _walk_for_vehicles(root, out)
    return out


func _walk_for_vehicles(node: Node, out: Array[Node3D]) -> void:
    if node == null:
        return
    var scriptPath: String = node.get_script().resource_path if node.get_script() != null else ""
    if TRACKED_SCRIPTS.has(scriptPath) && node is Node3D:
        out.append(node as Node3D)
        return
    for child: Node in node.get_children():
        _walk_for_vehicles(child, out)


@rpc("authority", "call_remote", "unreliable")
func sync_vehicle_snapshot(relPath: String, pos: Vector3, rotQuat: Quaternion, turretRot: float) -> void:
    _snapshots[relPath] = {
        &"pos": pos,
        &"rot": rotQuat,
        &"turret": turretRot,
    }


## Returns empty dict if no snapshot yet so caller can fall through to super.
func get_snapshot(relPath: String) -> Dictionary:
    return _snapshots.get(relPath, {})
