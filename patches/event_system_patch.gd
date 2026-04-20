## Co-op patch for EventSystem.gd
##
## Problem: EventSystem uses unseeded RNG (randi_range, pick_random) so each
## peer rolls different events with different timings. Helicopters, BTRs,
## airdrops, and crash sites appear in different places (or not at all) on
## host vs client.
##
## Fix: Host runs all event selection and activation logic. Clients skip
## event rolls entirely and receive spawn commands via world_state RPCs.
## Each event function is overridden to broadcast its random parameters so
## clients reproduce the exact same spawn.
##
## Original behavior preserved in singleplayer (no CoopManager).
extends "res://Scripts/EventSystem.gd"


var _cm: Node


func _ready() -> void:
    _ensure_cm()
    # Host + solo paths run vanilla _ready verbatim — benefits from any future
    # base-game additions (new @onready vars, new timer, etc.) without us
    # re-tracking. Client path skips activations because host broadcasts them.
    if _cm != null && _cm.is_session_active() && !_cm.isHost:
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


# ---------- Simple Events (no params) ----------


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


# ---------- Parameterized Events ----------


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


# ---------- Trader Events (already synced via trader_patch) ----------
# ActivateTrader / DeactivateTrader: host runs normally via super calls
# in ActivateTraderEvent. Clients skip ActivateTraderEvent entirely in
# _ready, so no duplicate activation. Trader state comes from trader_patch.


# ---------- Spawn Helpers ----------


## Spawns a path-following vehicle (Police or BTR) at a specific path + direction.
## Extracted from original Police()/BTR() to allow deterministic replay on clients.
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


## Spawns a crash site at a specific crash node index.
func _spawn_crash(crashIndex: int) -> void:
    var randomCrash: Node3D = crashes.get_child(crashIndex)
    var crashSite: Node3D = crash.instantiate()
    randomCrash.add_child(crashSite)
    crashSite.global_transform = randomCrash.global_transform


## Spawns the cat at a specific well index.
func _spawn_cat(wellIndex: int) -> void:
    var wells: Array[Node] = get_tree().get_nodes_in_group(&"Well")
    if wellIndex >= wells.size():
        return
    var randomWell: Node3D = wells[wellIndex]
    var wellBottom: Node3D = randomWell.get_node_or_null("Bottom")
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


## Called by world_state RPC on clients to replay a host event.
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
