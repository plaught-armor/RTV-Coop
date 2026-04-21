## Host-authoritative transform sync for [code]Helicopter[/code] and [code]BTR[/code].
## Host broadcasts position + rotation + turret angle at 10Hz; clients patch
## the vehicle scripts to skip their state machines and drive the visual from
## the latest snapshot. Gameplay (sensor, fire, rockets) stays on the host.
##
## Rocket and shell spawning are intentionally NOT replicated — the research
## notes flag visual divergence between peers as cosmetic only ("each player
## gets their own private heli attack, not catastrophic").
extends Node

var _cm: Node
## Cached scene ref. Refreshed per scene transition.
var _currentScene: Node = null

## [relPath: String] → { pos: Vector3, rot: Quaternion, turret: float }.
## Clients read the latest entry every physics frame inside the patch overrides.
var _snapshots: Dictionary = {}

## Send every 12th physics tick (120Hz / 12 = 10Hz). Matches [code]ai_state.gd[/code]
## cadence so bandwidth + jitter profiles stay consistent across replicated systems.
const SEND_EVERY_N_TICKS: int = 12


func init_manager(manager: Node) -> void:
    _cm = manager


## Called from [method CoopManager.on_scene_changed]. Snapshots don't survive
## scene transitions — every entry points at a now-freed Node by path.
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


## Scans the scene for Helicopter / BTR nodes by script path (take_over_path
## preserves the original path on the patched script) and sends one snapshot
## per vehicle.
func _broadcast_vehicle_snapshots() -> void:
    for vehicle: Node3D in _collect_vehicles(_currentScene):
        var relPath: String = String(_currentScene.get_path_to(vehicle))
        var rotQuat: Quaternion = vehicle.global_transform.basis.get_rotation_quaternion()
        var turretRot: float = 0.0
        var tower: Node = vehicle.get_node_or_null(^"Chassis/Tower")
        if is_instance_valid(tower) && tower is Node3D:
            turretRot = (tower as Node3D).rotation.y
        sync_vehicle_snapshot.rpc(relPath, vehicle.global_transform.origin, rotQuat, turretRot)


## Recursive scene walk for vehicle nodes. Stops descending once a vehicle is
## found — children of a Helicopter/BTR can't be vehicles themselves.
func _collect_vehicles(root: Node) -> Array[Node3D]:
    var out: Array[Node3D] = []
    _walk_for_vehicles(root, out)
    return out


func _walk_for_vehicles(node: Node, out: Array[Node3D]) -> void:
    if node == null:
        return
    var scriptPath: String = node.get_script().resource_path if node.get_script() != null else ""
    if (scriptPath == "res://Scripts/Helicopter.gd" || scriptPath == "res://Scripts/BTR.gd") && node is Node3D:
        out.append(node as Node3D)
        return
    for child: Node in node.get_children():
        _walk_for_vehicles(child, out)


## Clients store the latest transform snapshot for a vehicle keyed by its
## scene-relative path. Unreliable — the next tick will correct any drops.
@rpc("authority", "call_remote", "unreliable")
func sync_vehicle_snapshot(relPath: String, pos: Vector3, rotQuat: Quaternion, turretRot: float) -> void:
    _snapshots[relPath] = {
        &"pos": pos,
        &"rot": rotQuat,
        &"turret": turretRot,
    }


## Called by the vehicle patch overrides. Returns an empty dict when no
## snapshot has arrived yet, so the patch can fall through to [code]super[/code].
func get_snapshot(relPath: String) -> Dictionary:
    return _snapshots.get(relPath, {})
