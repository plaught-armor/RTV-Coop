## Patch for EventSystem.gd — host-auth event rolls; clients receive spawns via world_state RPC.
extends "res://Scripts/EventSystem.gd"


const PATH_WELL_BOTTOM: NodePath = ^"Bottom"


var _cm: Node


func _ready() -> void:
    if _ensure_cm() && _cm.is_session_active() && !_cm.isHost:
        paths = $Paths
        crashes = $Crashes
        await get_tree().create_timer(5.0, false).timeout
        if !is_instance_valid(self):
            return
        map = get_tree().current_scene.get_node(^"/root/Map")
        GetAvailableEvents()
        return
    super._ready()


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return false
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return true
    return false


func FighterJet() -> void:
    super.FighterJet()
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("FighterJet", PackedInt32Array())


func Helicopter() -> void:
    super.Helicopter()
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("Helicopter", PackedInt32Array())


func Airdrop() -> void:
    super.Airdrop()
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("Airdrop", PackedInt32Array())


func Transmission() -> void:
    super.Transmission()
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("Transmission", PackedInt32Array())


func Police() -> void:
    var pathIndex: int = randi_range(0, paths.get_child_count() - 1)
    var pathDirection: int = randi_range(1, 2)
    _spawn_pathed_vehicle(police, pathIndex, pathDirection)
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("Police", PackedInt32Array([pathIndex, pathDirection]))


func BTR() -> void:
    var pathIndex: int = randi_range(0, paths.get_child_count() - 1)
    var pathDirection: int = randi_range(1, 2)
    _spawn_pathed_vehicle(btr, pathIndex, pathDirection)
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("BTR", PackedInt32Array([pathIndex, pathDirection]))


func CrashSite() -> void:
    var crashIndex: int = randi_range(0, crashes.get_child_count() - 1)
    _spawn_crash(crashIndex)
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("CrashSite", PackedInt32Array([crashIndex]))


func Cat() -> void:
    if gameData.catFound || gameData.catDead:
        return
    var wells: Array[Node] = get_tree().get_nodes_in_group(&"Well")
    if wells.size() == 0:
        return
    var wellIndex: int = randi_range(0, wells.size() - 1)
    _spawn_cat(wellIndex)
    if _cm != null && _cm.is_session_active() && _cm.isHost:
        _cm.worldState.broadcast_event.rpc("Cat", PackedInt32Array([wellIndex]))


# Trader events: host via ActivateTraderEvent super; clients skip and receive via trader_patch.


func _spawn_pathed_vehicle(scene: PackedScene, pathIndex: int, pathDirection: int) -> void:
    var randomPath: Node3D = paths.get_child(pathIndex)
    var inversePath: bool
    var initialWaypoint: Node3D
    if pathDirection == 1:
        inversePath = false
        initialWaypoint = randomPath.get_child(0)
    else:
        inversePath = true
        initialWaypoint = randomPath.get_child(randomPath.get_child_count() - 1)
    var instance: Node3D = scene.instantiate()
    add_child(instance)
    instance.selectedPath = randomPath
    instance.inversePath = inversePath
    instance.global_transform = initialWaypoint.global_transform


func _spawn_crash(crashIndex: int) -> void:
    var randomCrash: Node3D = crashes.get_child(crashIndex)
    var crashSite: Node3D = crash.instantiate()
    randomCrash.add_child(crashSite)
    crashSite.global_transform = randomCrash.global_transform


func _spawn_cat(wellIndex: int) -> void:
    var wells: Array[Node] = get_tree().get_nodes_in_group(&"Well")
    if wellIndex >= wells.size():
        return
    var randomWell: Node3D = wells[wellIndex]
    var wellBottom: Node3D = randomWell.get_node_or_null(PATH_WELL_BOTTOM)
    if wellBottom == null:
        return
    var catInstance: Node3D = cat.instantiate()
    wellBottom.add_child(catInstance)
    catInstance.global_transform = wellBottom.global_transform
    var catSystem: Node = catInstance.get_child(0) if catInstance.get_child_count() > 0 else null
    if catSystem == null:
        return
    catSystem.currentState = catSystem.State.Rescue
    var rescueInstance: Node3D = rescue.instantiate()
    wellBottom.add_child(rescueInstance)
    rescueInstance.global_transform = wellBottom.global_transform
    rescueInstance.cat = catInstance
    rescueInstance.position.y = 3.0


func receive_event(eventName: String, params: PackedInt32Array) -> void:
    match eventName:
        "FighterJet":
            super.FighterJet()
        "Helicopter":
            super.Helicopter()
        "Airdrop":
            super.Airdrop()
        "Transmission":
            super.Transmission()
        "Police":
            if params.size() >= 2:
                _spawn_pathed_vehicle(police, params[0], params[1])
        "BTR":
            if params.size() >= 2:
                _spawn_pathed_vehicle(btr, params[0], params[1])
        "CrashSite":
            if params.size() >= 1:
                _spawn_crash(params[0])
        "Cat":
            if params.size() >= 1:
                _spawn_cat(params[0])
