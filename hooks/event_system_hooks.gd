## Hook callbacks for EventSystem.gd — host-auth event rolls; clients receive spawns via world_state RPC.
## Replaces patches/event_system_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## `dispatch_event(es, name, params)` is called from world_state.broadcast_event RPC handler
## to spawn host-rolled events on clients deterministically.
extends RefCounted


const PATH_WELL_BOTTOM: NodePath = ^"Bottom"

var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("eventsystem-_ready", _on_ready)
    # Simple post-broadcast methods (vanilla runs, then broadcast on host).
    for m: String in ["fighterjet", "helicopter", "airdrop", "transmission", "deactivatetrader"]:
        lib.hook("eventsystem-" + m + "-post", Callable(self, "_post_simple").bind(m))
    # Replace-impl methods (need RNG capture before spawn).
    lib.hook("eventsystem-police", _on_police)
    lib.hook("eventsystem-btr", _on_btr)
    lib.hook("eventsystem-crashsite", _on_crashsite)
    lib.hook("eventsystem-cat", _on_cat)


func _on_ready() -> void:
    var es: Node = _lib._caller
    if es == null:
        return
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return  # vanilla runs
    _lib.skip_super()
    es.paths = es.get_node(^"Paths")
    es.crashes = es.get_node(^"Crashes")
    await es.get_tree().create_timer(5.0, false).timeout
    if !is_instance_valid(es):
        return
    es.map = es.get_tree().current_scene.get_node(^"/root/Map")
    es.GetAvailableEvents()
    var traderCount: int = es.get_tree().get_nodes_in_group(&"Trader").size()
    var mapName: String = es.map.get(&"mapName") if es.map != null else "?"
    var mapType: String = es.map.get(&"mapType") if es.map != null else "?"
    var simDay: int = -1
    if Engine.has_singleton("Simulation"):
        simDay = Engine.get_singleton("Simulation").day
    else:
        var sim: Node = es.get_tree().root.get_node_or_null(^"/root/Simulation")
        if sim != null:
            simDay = int(sim.day)
    var fnames: Array[String] = []
    for ev: Resource in es.traderEvents:
        fnames.append("%s(d%d->%s)" % [ev.name, ev.day, ev.function])
    print("[event_system] CLIENT activate map=%s zone=%s day=%d traders_in_scene=%d traderEvents=%d %s" % [mapName, mapType, simDay, traderCount, es.traderEvents.size(), str(fnames)])
    es.ActivateTraderEvent()
    var visibleAfter: int = 0
    for t: Node in es.get_tree().get_nodes_in_group(&"Trader"):
        if t.visible:
            visibleAfter += 1
    print("[event_system] CLIENT post-activate visible=%d/%d" % [visibleAfter, traderCount])


# Generic post-hook: vanilla just ran, broadcast event name w/ no params on host.
func _post_simple(eventName: String) -> void:
    if CoopManager == null || !CoopManager.is_session_active() || !CoopManager.isHost:
        return
    var label: String = ""
    match eventName:
        "fighterjet":       label = "FighterJet"
        "helicopter":       label = "Helicopter"
        "airdrop":          label = "Airdrop"
        "transmission":     label = "Transmission"
        "deactivatetrader": label = "DeactivateTrader"
        _: return
    CoopManager.worldState.broadcast_event.rpc(label, PackedInt32Array())


func _on_police() -> void:
    var es: Node = _lib._caller
    if es == null:
        return
    _lib.skip_super()
    var pathIndex: int = randi_range(0, es.paths.get_child_count() - 1)
    var pathDir: int = randi_range(1, 2)
    _spawn_pathed_vehicle(es, es.police, pathIndex, pathDir)
    if CoopManager.is_session_active() && CoopManager.isHost:
        CoopManager.worldState.broadcast_event.rpc("Police", PackedInt32Array([pathIndex, pathDir]))


func _on_btr() -> void:
    var es: Node = _lib._caller
    if es == null:
        return
    _lib.skip_super()
    var pathIndex: int = randi_range(0, es.paths.get_child_count() - 1)
    var pathDir: int = randi_range(1, 2)
    _spawn_pathed_vehicle(es, es.btr, pathIndex, pathDir)
    if CoopManager.is_session_active() && CoopManager.isHost:
        CoopManager.worldState.broadcast_event.rpc("BTR", PackedInt32Array([pathIndex, pathDir]))


func _on_crashsite() -> void:
    var es: Node = _lib._caller
    if es == null:
        return
    _lib.skip_super()
    var crashIndex: int = randi_range(0, es.crashes.get_child_count() - 1)
    _spawn_crash(es, crashIndex)
    if CoopManager.is_session_active() && CoopManager.isHost:
        CoopManager.worldState.broadcast_event.rpc("CrashSite", PackedInt32Array([crashIndex]))


func _on_cat() -> void:
    var es: Node = _lib._caller
    if es == null:
        return
    _lib.skip_super()
    if es.gameData.catFound || es.gameData.catDead:
        return
    var wells: Array[Node] = es.get_tree().get_nodes_in_group(&"Well")
    if wells.size() == 0:
        return
    var wellIndex: int = randi_range(0, wells.size() - 1)
    _spawn_cat(es, wellIndex)
    if CoopManager.is_session_active() && CoopManager.isHost:
        CoopManager.worldState.broadcast_event.rpc("Cat", PackedInt32Array([wellIndex]))


# Called from world_state.broadcast_event RPC on client to reproduce host's roll.
func dispatch_event(es: Node, eventName: String, params: PackedInt32Array) -> void:
    if es == null:
        return
    match eventName:
        "FighterJet":       es.FighterJet()
        "Helicopter":       es.Helicopter()
        "Airdrop":          es.Airdrop()
        "Transmission":     es.Transmission()
        "DeactivateTrader": es.DeactivateTrader()
        "Police":
            if params.size() >= 2:
                _spawn_pathed_vehicle(es, es.police, params[0], params[1])
        "BTR":
            if params.size() >= 2:
                _spawn_pathed_vehicle(es, es.btr, params[0], params[1])
        "CrashSite":
            if params.size() >= 1:
                _spawn_crash(es, params[0])
        "Cat":
            if params.size() >= 1:
                _spawn_cat(es, params[0])


func _spawn_pathed_vehicle(es: Node, scene: PackedScene, pathIndex: int, pathDirection: int) -> void:
    var randomPath: Node3D = es.paths.get_child(pathIndex)
    var inversePath: bool
    var initialWaypoint: Node3D
    if pathDirection == 1:
        inversePath = false
        initialWaypoint = randomPath.get_child(0)
    else:
        inversePath = true
        initialWaypoint = randomPath.get_child(randomPath.get_child_count() - 1)
    var instance: Node3D = scene.instantiate()
    es.add_child(instance)
    instance.selectedPath = randomPath
    instance.inversePath = inversePath
    instance.global_transform = initialWaypoint.global_transform


func _spawn_crash(es: Node, crashIndex: int) -> void:
    var randomCrash: Node3D = es.crashes.get_child(crashIndex)
    var crashSite: Node3D = es.crash.instantiate()
    randomCrash.add_child(crashSite)
    crashSite.global_transform = randomCrash.global_transform


func _spawn_cat(es: Node, wellIndex: int) -> void:
    var wells: Array[Node] = es.get_tree().get_nodes_in_group(&"Well")
    if wellIndex >= wells.size():
        return
    var randomWell: Node3D = wells[wellIndex]
    var wellBottom: Node3D = randomWell.get_node_or_null(PATH_WELL_BOTTOM)
    if wellBottom == null:
        return
    var catInstance: Node3D = es.cat.instantiate()
    wellBottom.add_child(catInstance)
    catInstance.global_transform = wellBottom.global_transform
    var catSystem: Node = catInstance.get_child(0) if catInstance.get_child_count() > 0 else null
    if catSystem == null:
        return
    catSystem.currentState = catSystem.State.Rescue
    var rescueInstance: Node3D = es.rescue.instantiate()
    wellBottom.add_child(rescueInstance)
    rescueInstance.global_transform = wellBottom.global_transform
    rescueInstance.cat = catInstance
    rescueInstance.position.y = 3.0
