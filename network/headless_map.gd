## Manages a headless SubViewport for a map where clients are present but the host
## is not. AI runs in the SubViewport's own physics world. A cloned GameData proxy
## isolates AI detection from the host's real GameData.
extends Node

var _cm: Node
var mapPath: String = ""
var viewport: SubViewport = null
var mapScene: Node = null
var proxyGameData: Resource = null
var clientPeers: Array[int] = []
var aiSyncIdCounter: int = 0
var syncedAI: Dictionary[int, Node] = {}
var clientPositions: Dictionary[int, Dictionary] = {}
var savedSnapshot: Dictionary = {}

enum AIType { BANDIT, GUARD, MILITARY, PUNISHER }
const AI_SYNC_FRAMES: int = 12

var _realGameData: Resource = preload("res://Resources/GameData.tres")


func init_manager(manager: Node) -> void:
    _cm = manager


func setup(path: String) -> bool:
    mapPath = path
    viewport = SubViewport.new()
    viewport.name = "Headless_%s" % path.get_file().get_basename()
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    viewport.physics_object_picking = false
    viewport.gui_disable_input = true
    viewport.process_mode = Node.PROCESS_MODE_DISABLED
    add_child(viewport)

    var scene: PackedScene = load(path)
    if scene == null:
        push_error("[HeadlessMap] Failed to load scene: %s" % path)
        return false
    mapScene = scene.instantiate()
    viewport.add_child(mapScene)

    var core: Node = mapScene.get_node_or_null("Core")
    if core != null:
        core.queue_free()

    _inject_proxy_gamedata()
    _log("SubViewport created for %s" % path)
    return true


func start() -> void:
    if viewport == null:
        return
    viewport.process_mode = Node.PROCESS_MODE_INHERIT
    _register_ai_sync_ids.call_deferred()
    _log("SubViewport started for %s" % mapPath)


func _inject_proxy_gamedata() -> void:
    proxyGameData = _realGameData.duplicate()
    proxyGameData.isDead = false
    proxyGameData.isFlying = false
    proxyGameData.isCaching = false
    proxyGameData.isTrading = false
    _walk_and_inject(mapScene)


func _walk_and_inject(node: Node) -> void:
    if "gameData" in node:
        node.gameData = proxyGameData
    for child: Node in node.get_children():
        _walk_and_inject(child)


func _register_ai_sync_ids() -> void:
    if mapScene == null:
        return
    for node: Node in _get_all_ai_nodes():
        if node.has_meta(&"ai_sync_id"):
            continue
        aiSyncIdCounter += 1
        node.set_meta(&"ai_sync_id", aiSyncIdCounter)
        node.set_meta(&"ai_type", _get_ai_type(node))
        syncedAI[aiSyncIdCounter] = node


func _get_all_ai_nodes() -> Array[Node]:
    var result: Array[Node] = []
    if mapScene == null:
        return result
    _collect_ai_recursive(mapScene, result)
    return result


func _collect_ai_recursive(node: Node, result: Array[Node]) -> void:
    if node is CharacterBody3D && node.has_method("Sensor"):
        result.append(node)
    for child: Node in node.get_children():
        _collect_ai_recursive(child, result)


func _get_ai_type(node: Node) -> int:
    var scenePath: String = node.scene_file_path
    if "Bandit" in scenePath:
        return AIType.BANDIT
    elif "Guard" in scenePath:
        return AIType.GUARD
    elif "Military" in scenePath:
        return AIType.MILITARY
    elif "Punisher" in scenePath:
        return AIType.PUNISHER
    return AIType.BANDIT

# ---------- Client Management ----------


func add_client(peerId: int) -> void:
    if peerId not in clientPeers:
        clientPeers.append(peerId)
        _log("Client %d added to headless %s" % [peerId, mapPath])


func remove_client(peerId: int) -> void:
    var idx: int = clientPeers.find(peerId)
    if idx >= 0:
        clientPeers.remove_at(idx)
    clientPositions.erase(peerId)
    _log("Client %d removed from headless %s" % [peerId, mapPath])

# ---------- Position Injection ----------


func update_client_position(peerId: int, pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    if proxyGameData == null:
        return
    clientPositions[peerId] = {
        "pos": pos, "camPos": camPos, "rot": rot, "flags": flags,
    }
    if clientPositions.size() == 1:
        _apply_client_to_proxy(pos, camPos, rot, flags)
        return
    # Multiple clients: use nearest to AI centroid
    var centroid: Vector3 = _get_ai_centroid()
    var nearestDist: float = INF
    var nearestData: Dictionary = {}
    for pid: int in clientPositions:
        var data: Dictionary = clientPositions[pid]
        var dist: float = centroid.distance_squared_to(data["pos"])
        if dist < nearestDist:
            nearestDist = dist
            nearestData = data
    if !nearestData.is_empty():
        _apply_client_to_proxy(nearestData["pos"], nearestData["camPos"], nearestData["rot"], nearestData["flags"])


func _apply_client_to_proxy(pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    proxyGameData.playerPosition = pos
    proxyGameData.cameraPosition = camPos
    proxyGameData.playerVector = -Vector3(sin(rot.y), 0, cos(rot.y))
    proxyGameData.isRunning = (flags & 4) != 0
    proxyGameData.isWalking = (flags & 2) != 0
    proxyGameData.isMoving = (flags & 1) != 0


func _get_ai_centroid() -> Vector3:
    var sum: Vector3 = Vector3.ZERO
    var count: int = 0
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai):
            continue
        if ai.get("dead") == true || ai.get("pause") == true:
            continue
        sum += ai.global_position
        count += 1
    if count == 0:
        return Vector3.ZERO
    return sum / float(count)

# ---------- AI State Extraction ----------


func extract_ai_state() -> Array[Dictionary]:
    var states: Array[Dictionary] = []
    var toErase: Array[int] = []
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai):
            toErase.append(syncId)
            continue
        if ai.get("dead") == true || ai.get("pause") == true:
            continue
        states.append({
            "id": syncId,
            "type": ai.get_meta(&"ai_type", 0),
            "pos": ai.global_position,
            "rot_y": ai.global_rotation.y,
            "state": ai.get("currentState") if ai.get("currentState") != null else 0,
            "speed": ai.get("movementSpeed") if ai.get("movementSpeed") != null else 0.0,
            "move_rot": ai.get("movementRotation") if ai.get("movementRotation") != null else 0.0,
            "health": ai.get("health") if ai.get("health") != null else 100,
            "dead": ai.get("dead") == true,
        })
    for id: int in toErase:
        syncedAI.erase(id)
    return states


func get_new_spawns() -> Array[Dictionary]:
    var spawns: Array[Dictionary] = []
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai):
            continue
        if ai.has_meta(&"spawn_notified"):
            continue
        ai.set_meta(&"spawn_notified", true)
        spawns.append({
            "id": syncId,
            "type": ai.get_meta(&"ai_type", 0),
            "pos": ai.global_position,
        })
    return spawns

# ---------- World State ----------


func extract_door_states() -> Dictionary:
    var doors: Dictionary = {}
    if mapScene == null:
        return doors
    for node: Node in mapScene.get_tree().get_nodes_in_group("Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if !(obj is Door):
            continue
        var doorPath: String = mapScene.get_path_to(obj)
        doors[doorPath] = {
            "isOpen": obj.get("isOpen") if obj.get("isOpen") != null else false,
            "locked": obj.get("locked") if obj.get("locked") != null else false,
        }
    return doors


func extract_switch_states() -> Dictionary:
    var switches: Dictionary = {}
    if mapScene == null:
        return switches
    for node: Node in mapScene.get_tree().get_nodes_in_group("Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if !obj.has_method("Activate"):
            continue
        var switchPath: String = mapScene.get_path_to(obj)
        switches[switchPath] = obj.get("active") if obj.get("active") != null else false
    return switches

# ---------- Snapshot / Restore ----------


func snapshot() -> Dictionary:
    var snap: Dictionary = {
        "ai": [],
        "doors": extract_door_states(),
        "switches": extract_switch_states(),
    }
    for syncId: int in syncedAI:
        var ai: Node = syncedAI[syncId]
        if !is_instance_valid(ai) || ai.get("dead") == true:
            continue
        snap["ai"].append({
            "type": ai.get_meta(&"ai_type", 0),
            "pos": ai.global_position,
            "rot_y": ai.global_rotation.y,
            "state": ai.get("currentState") if ai.get("currentState") != null else 0,
            "health": ai.get("health") if ai.get("health") != null else 100,
        })
    return snap


func restore(snap: Dictionary) -> void:
    if mapScene == null:
        return
    var doors: Dictionary = snap.get("doors", {})
    for doorPath: String in doors:
        var door: Node = mapScene.get_node_or_null(doorPath)
        if !is_instance_valid(door) || !(door is Door):
            continue
        var state: Dictionary = doors[doorPath]
        door.isOpen = state.get("isOpen", false)
        door.locked = state.get("locked", false)
        if door.isOpen:
            door.animationTime = 4.0
    var switches: Dictionary = snap.get("switches", {})
    for switchPath: String in switches:
        var sw: Node = mapScene.get_node_or_null(switchPath)
        if !is_instance_valid(sw) || !sw.has_method("Activate"):
            continue
        var active: bool = switches[switchPath]
        if active && !sw.active:
            sw.Activate()
        elif !active && sw.active:
            sw.Deactivate()
    var aiSnaps: Array = snap.get("ai", [])
    if aiSnaps.is_empty():
        return
    var poolAI: Array[Node] = _get_all_ai_nodes()
    var usedNodes: Array[Node] = []
    for aiSnap: Dictionary in aiSnaps:
        var targetType: int = aiSnap.get("type", 0)
        var targetPos: Vector3 = aiSnap.get("pos", Vector3.ZERO)
        var targetRotY: float = aiSnap.get("rot_y", 0.0)
        var targetHealth: int = aiSnap.get("health", 100)
        var matched: Node = null
        for ai: Node in poolAI:
            if ai in usedNodes:
                continue
            if _get_ai_type(ai) == targetType:
                matched = ai
                break
        if matched == null:
            continue
        usedNodes.append(matched)
        matched.global_position = targetPos
        matched.global_rotation.y = targetRotY
        if "health" in matched:
            matched.health = targetHealth
    _log("Restored %d AI, %d doors, %d switches from snapshot" % [
        usedNodes.size(), doors.size(), switches.size()
    ])


func teardown() -> void:
    savedSnapshot = snapshot()
    if viewport != null:
        viewport.queue_free()
        viewport = null
    mapScene = null
    syncedAI.clear()
    clientPositions.clear()
    _log("SubViewport torn down for %s" % mapPath)


func _log(msg: String) -> void:
    print("[HeadlessMap] %s" % msg)
