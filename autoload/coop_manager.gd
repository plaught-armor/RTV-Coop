## Main mod autoload: peer lifecycle, patch injection, remote spawn, Steam, scene changes.
extends Node

const DEFAULT_PORT: int = 9050
const MAX_CLIENTS: int = 3
var DEBUG: bool = OS.has_feature("editor")
var localPeerId: int = 0
var isHost: bool = false
var isActive: bool = false
# Parallel arrays indexed by peerIdx; -1 in peerGodotIds is a tombstone.
var peerGodotIds: PackedInt32Array = []
var peerNames: PackedStringArray = []
var peerSteamIDs: PackedStringArray = []
var peerMaps: PackedStringArray = []
var remoteNodes: Array[Node3D] = []
var cachedAppearances: Array[Dictionary] = []
var cachedEquipment: PackedStringArray = []
var cachedAttachments: Array[Array] = []
var peerIdxByGodotId: Dictionary[int, int] = {}
var avatarCache: Dictionary[String, ImageTexture] = { }
var headlessMaps: Dictionary[String, Node] = {}
var mapSnapshots: Dictionary[String, Dictionary] = {}
# Host-owned session settings broadcast to every peer (update via set_setting).
var settings: Dictionary[String, float] = {
    "day_rate_multiplier": 1.0,
    "night_rate_multiplier": 1.0,
}
var playerState: Node = null
var worldState: Node = null
var aiState: Node = null
var vehicleState: Node = null
var steamBridge: Node = null
var loader: Node = null
var coopUI: Control = null
# Written by coop_menu_customizer, read by settings_patch. Dynamic access only.
@warning_ignore("unused_private_class_variable")
var _pendingHostUseSteam: bool = true

var remotePlayerScene: PackedScene = preload("res://mod/presentation/remote_player.tscn")
var PlayerStateScript: Script = preload("res://mod/network/player_state.gd")
var slotSerializer: RefCounted = preload("res://mod/network/slot_serializer.gd").new()
var HeadlessMapScript: Script = preload("res://mod/network/headless_map.gd")
# Cached before take_over_path to avoid circular extends after path redirect.
var PickupPatchScript: Script = preload("res://mod/patches/pickup_patch.gd")
var AIPatchScript: Script = preload("res://mod/patches/ai_patch.gd")
var appearance: RefCounted = preload("res://mod/network/appearance.gd").new()
var perf: RefCounted = preload("res://mod/network/perf.gd").new()
var logCollector: RefCounted = preload("res://mod/autoload/log_collector.gd").new()
var saveMirror: RefCounted = preload("res://mod/autoload/save_mirror.gd").new()
var gameState: RefCounted = preload("res://mod/autoload/coop_game_state.gd").new()
var _interactRouter: RefCounted = preload("res://mod/autoload/coop_interact_router.gd").new()
var layoutsHook: RefCounted = preload("res://mod/network/layouts_hook.gd").new()
var simulationHook: RefCounted = preload("res://mod/network/simulation_hook.gd").new()
var catStateHook: RefCounted = preload("res://mod/network/cat_state_hook.gd").new()
var deathStateHook: RefCounted = preload("res://mod/network/death_state_hook.gd").new()
var MenuCustomizerScript: Script = preload("res://mod/autoload/coop_menu_customizer.gd")
var menuCustomizer: Node = null
var audioLibrary: AudioLibrary = preload("res://Resources/AudioLibrary.tres")
var gd: GameData = preload("res://Resources/GameData.tres")
var lastScenePath: String = ""
var itemRegistrationTimer: SceneTreeTimer = null
var worldId: String = ""
# 60 physics frames ~= 0.5s at 120Hz.
const SCENE_CHECK_FRAMES: int = 60

const PATH_CONTROLLER: NodePath = ^"Core/Controller"
const PATH_AI: NodePath = ^"AI"
const PATH_CORE: NodePath = ^"Core"
const PATH_LOADER_ABS: NodePath = ^"/root/Loader"
const PATH_DATABASE_ABS: NodePath = ^"/root/Database"
const PATH_MENU_SUBMENU: NodePath = ^"CoopMPSubmenu"
var pendingAutoJoin: bool = false
# Suppress mirror_user_to_solo on menu return; client user:// may hold stale writes.
var _wasInCoop: bool = false
var currentLobbyID: String = ""
var _wasOnMenu: bool = true
var _autoLoadInProgress: bool = false
var _recheckPending: bool = false
const _RECHECK_TIMEOUT_SEC: float = 5.0


func _ready() -> void:
    # Editor autoloads via project.godot -> /root/CoopManager.
    # Exported build autoloads via ModLoader -> /root/RTVModLoader/CoopManager.
    # RPC uses NodePath across peers, so force /root/CoopManager on both sides.
    _normalize_autoload_path.call_deferred()
    set_meta(&"is_coop_manager", true)
    if DEBUG:
        force_windowed()

    register_patches()
    loader = get_node_or_null(PATH_LOADER_ABS)
    saveMirror.init_manager(self)
    gameState.init_manager(self)
    layoutsHook.init_manager.call_deferred(self)
    simulationHook.init_manager(self)
    catStateHook.init_manager(self)
    deathStateHook.init_manager(self)

    _spawn_network_children()
    _spawn_coop_ui()
    _connect_multiplayer_signals()

    # One-time migration: move pre-mod solo saves out of user:// root so they
    # don't get clobbered when the player hosts a coop world.
    migrate_solo_saves_if_needed()

    _maybe_customize_menu.call_deferred(get_tree().current_scene)
    _register_ai_pools.call_deferred()
    _log("Initialized (debug: %s)" % str(DEBUG))


func _normalize_autoload_path() -> void:
    var root: Window = get_tree().root
    if get_parent() != root:
        get_parent().remove_child(self)
        root.add_child(self)
    name = "CoopManager"


func _spawn_network_children() -> void:
    var PlayerStateScript_: Script = preload("res://mod/network/player_state.gd")
    var WorldStateScript: Script = preload("res://mod/network/world_state.gd")
    var AIStateScript: Script = preload("res://mod/network/ai_state.gd")
    var SteamBridgeScript: Script = preload("res://mod/network/steam_bridge.gd")

    playerState = PlayerStateScript_.new()
    playerState.name = "PlayerState"
    add_child(playerState)
    playerState.init_manager(self)

    worldState = WorldStateScript.new()
    worldState.name = "WorldState"
    add_child(worldState)
    worldState.init_manager(self)

    aiState = AIStateScript.new()
    aiState.name = "AIState"
    add_child(aiState)
    aiState.init_manager(self)

    var VehicleStateScript: Script = preload("res://mod/network/vehicle_state.gd")
    vehicleState = VehicleStateScript.new()
    vehicleState.name = "VehicleState"
    add_child(vehicleState)
    vehicleState.init_manager(self)

    steamBridge = SteamBridgeScript.new()
    steamBridge.name = "SteamBridge"
    add_child(steamBridge)
    steamBridge.init_manager(self)
    steamBridge.launch()

    menuCustomizer = MenuCustomizerScript.new()
    menuCustomizer.name = "MenuCustomizer"
    add_child(menuCustomizer)
    menuCustomizer.init_manager(self)


func _spawn_coop_ui() -> void:
    var uiLayer: CanvasLayer = CanvasLayer.new()
    uiLayer.name = "CoopUILayer"
    uiLayer.layer = 100
    add_child(uiLayer)
    var CoopUIScript: Script = preload("res://mod/ui/coop_ui.gd")
    var CoopHUDScript: Script = preload("res://mod/ui/coop_hud.gd")
    coopUI = CoopUIScript.new()
    coopUI.name = "CoopUI"
    uiLayer.add_child(coopUI)
    coopUI.init_manager(self)

    var coopHUD: VBoxContainer = CoopHUDScript.new()
    coopHUD.name = "CoopHUD"
    uiLayer.add_child(coopHUD)
    coopHUD.init_manager(self)


func _connect_multiplayer_signals() -> void:
    multiplayer.peer_connected.connect(on_peer_connected)
    multiplayer.peer_disconnected.connect(on_peer_disconnected)
    multiplayer.connected_to_server.connect(on_connected_to_server)
    multiplayer.connection_failed.connect(on_connection_failed)
    multiplayer.server_disconnected.connect(on_server_disconnected)


func _process(delta: float) -> void:
    simulationHook.apply(delta)
    catStateHook.poll()
    deathStateHook.poll()


func _physics_process(_delta: float) -> void:
    if Engine.get_physics_frames() % 30 == 0:
        _update_mp_status()

    if Engine.get_physics_frames() % SCENE_CHECK_FRAMES != 0:
        return

    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var currentPath: String = scene.scene_file_path
    if currentPath != lastScenePath:
        lastScenePath = currentPath
        call_deferred("on_scene_changed")
    elif isActive:
        ensure_all_spawned()


func _update_mp_status() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var submenu: Node = scene.get_node_or_null(PATH_MENU_SUBMENU)
    if submenu == null:
        return
    var hostBtn: Button = submenu.find_child("HostBtn", true, false) as Button
    var browseBtn: Button = submenu.find_child("BrowseBtn", true, false) as Button
    var bridge_ready: bool = is_instance_valid(steamBridge) && steamBridge.is_ready() && steamBridge.ownsGame
    if hostBtn != null:
        hostBtn.disabled = !bridge_ready
    if browseBtn != null:
        browseBtn.disabled = !bridge_ready


func register_patches() -> void:
    var registry: RefCounted = preload("res://mod/autoload/patch_registry.gd").new()
    var count: int = registry.register_all()
    _log("Patches registered (%d)" % count)


# AISpawner preloads AI body scenes at parse time, caching them with the original
# AI.gd script. Puppet rigs need the patched script to pick up puppetMode.
func ensure_ai_patch_script(ai: Node) -> void:
    var s: Script = ai.get_script()
    if s == null || s.resource_path == "res://Scripts/AI.gd":
        ai.set_script(AIPatchScript)


## Starts ENet server + optional Steam lobby; world/save setup deferred until finalize_host.
func start_hosting(port: int = DEFAULT_PORT, useSteam: bool = true) -> bool:
    if is_session_active():
        _log("Already connected, disconnect first")
        return false
    if useSteam && !DEBUG && !steamBridge.ownsGame:
        _log("Cannot host — game ownership not verified")
        return false
    var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
    var error: Error = peer.create_server(port, MAX_CLIENTS)
    if error != OK:
        _log("Failed to create server: %s" % error)
        return false
    multiplayer.multiplayer_peer = peer
    localPeerId = multiplayer.get_unique_id()
    isHost = true
    isActive = true
    var localIdx: int = alloc_peer_slot(localPeerId)
    peerNames[localIdx] = steamBridge.localSteamName if steamBridge.is_ready() else "Host"
    peerMaps[localIdx] = get_current_map()

    if useSteam && steamBridge.is_ready():
        steamBridge.start_p2p_host(on_p2p_host_ready, port)
        steamBridge.create_lobby(MAX_CLIENTS + 1, on_lobby_created)
    elif !useSteam && is_instance_valid(steamBridge):
        steamBridge.abort_connect()

    _log("Hosting on port %d (id: %d, steam: %s)" % [port, localPeerId, str(useSteam)])
    return true


func finalize_host() -> void:
    worldState.start_item_tracking()
    saveMirror.setup_save_paths()
    _update_rich_presence()


func host_game(port: int = DEFAULT_PORT, useSteam: bool = true) -> void:
    if start_hosting(port, useSteam):
        finalize_host()


func join_game(address: String, port: int = DEFAULT_PORT, directConnect: bool = false) -> void:
    if is_session_active():
        _log("Already connected, disconnect first")
        return
    if !directConnect && !steamBridge.ownsGame && !DEBUG:
        _log("Cannot join — game ownership not verified")
        return
    var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
    var error: Error = peer.create_client(address, port)
    if error != OK:
        _log("Failed to connect: %s" % error)
        return
    # Generous timeout needed for handshake over P2P relay.
    var serverPeer: ENetPacketPeer = peer.get_peer(1)
    if serverPeer != null:
        serverPeer.set_timeout(0, 30000, 60000)
    multiplayer.multiplayer_peer = peer
    isHost = false
    if directConnect && is_instance_valid(steamBridge):
        steamBridge.abort_connect()
    _log("Connecting to %s:%d" % [address, port])


func disconnect_session() -> void:
    if !is_session_active():
        return

    # Stop subsystems before touching file state to kill in-flight RPCs.
    worldState.stop_item_tracking()

    # Mirror before nulling peer so late frame saves still have valid state (host only).
    var wasHost: bool = isHost
    if wasHost && !worldId.is_empty():
        saveMirror.mirror_user_to_world()

    for i: int in peerGodotIds.size():
        var pid: int = peerGodotIds[i]
        if pid == -1:
            continue
        playerState.clear_peer(pid)
        if is_instance_valid(remoteNodes[i]):
            remoteNodes[i].queue_free()
    peerGodotIds.resize(0)
    peerNames.resize(0)
    peerSteamIDs.resize(0)
    peerMaps.resize(0)
    remoteNodes.resize(0)
    cachedAppearances.resize(0)
    cachedEquipment.resize(0)
    cachedAttachments.resize(0)
    peerIdxByGodotId.clear()
    for mapPath: String in headlessMaps:
        var hmap: Node = headlessMaps[mapPath]
        hmap.teardown()
        hmap.queue_free()
    headlessMaps.clear()
    mapSnapshots.clear()
    multiplayer.multiplayer_peer = null
    localPeerId = 0
    isHost = false
    isActive = false
    pendingAutoJoin = false
    currentLobbyID = ""
    _autoLoadInProgress = false
    # Latches next menu-return path so _maybe_customize_menu skips mirror_user_to_solo.
    _wasInCoop = true

    # Wipe for host AND client: client user:// may hold stale transition writes.
    saveMirror.wipe_user_saves()
    saveMirror.clear_active_world()
    saveMirror.reset_save_paths()
    steamBridge.leave_lobby()
    steamBridge.clear_rich_presence()
    _log("Disconnected (was host: %s)" % str(wasHost))

func alloc_peer_slot(godotId: int) -> int:
    if peerIdxByGodotId.has(godotId):
        return peerIdxByGodotId[godotId]
    for i: int in peerGodotIds.size():
        if peerGodotIds[i] == -1:
            peerGodotIds[i] = godotId
            peerNames[i] = ""
            peerSteamIDs[i] = ""
            peerMaps[i] = ""
            remoteNodes[i] = null
            cachedAppearances[i] = {}
            cachedEquipment[i] = ""
            cachedAttachments[i] = []
            peerIdxByGodotId[godotId] = i
            return i
    var idx: int = peerGodotIds.size()
    peerGodotIds.append(godotId)
    peerNames.append("")
    peerSteamIDs.append("")
    peerMaps.append("")
    remoteNodes.append(null)
    cachedAppearances.append({})
    cachedEquipment.append("")
    cachedAttachments.append([])
    peerIdxByGodotId[godotId] = idx
    return idx


func free_peer_slot(idx: int) -> void:
    if idx < 0 || idx >= peerGodotIds.size() || peerGodotIds[idx] == -1:
        return
    var godotId: int = peerGodotIds[idx]
    peerGodotIds[idx] = -1
    peerNames[idx] = ""
    peerSteamIDs[idx] = ""
    peerMaps[idx] = ""
    if is_instance_valid(remoteNodes[idx]):
        remoteNodes[idx].queue_free()
    remoteNodes[idx] = null
    cachedAppearances[idx] = {}
    cachedEquipment[idx] = ""
    cachedAttachments[idx] = []
    peerIdxByGodotId.erase(godotId)


func peer_idx(godotId: int) -> int:
    return peerIdxByGodotId.get(godotId, -1)


func cache_peer_equipment(godotId: int, weaponName: String) -> void:
    cachedEquipment[alloc_peer_slot(godotId)] = weaponName


func cache_peer_appearance(godotId: int, entry: Dictionary) -> void:
    cachedAppearances[alloc_peer_slot(godotId)] = entry


func cache_peer_attachments(godotId: int, names: Array) -> void:
    cachedAttachments[alloc_peer_slot(godotId)] = names


func active_peer_idxs() -> PackedInt32Array:
    var out: PackedInt32Array = []
    for i: int in peerGodotIds.size():
        if peerGodotIds[i] != -1:
            out.append(i)
    return out


func active_peer_count() -> int:
    var n: int = 0
    for id: int in peerGodotIds:
        if id != -1:
            n += 1
    return n


func on_peer_connected(godotId: int) -> void:
    _log("Peer connected: %d" % godotId)
    alloc_peer_slot(godotId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc_id(godotId, get_local_name(), localSteamID)
    set_peer_timeout(godotId)
    _update_rich_presence()
    _update_lobby_data()
    var currentMap: String = get_current_map()
    if !currentMap.is_empty():
        sync_peer_map.rpc_id(godotId, currentMap)
    # Remote spawn waits for peer's sync_peer_map to confirm same-map.


func on_peer_disconnected(godotId: int) -> void:
    _log("Peer disconnected: %d" % godotId)
    var idx: int = peer_idx(godotId)
    if idx < 0:
        return
    playerState.clear_peer(godotId)
    var peerMap: String = peerMaps[idx]
    if isHost && !peerMap.is_empty() && peerMap in headlessMaps:
        var hmap: Node = headlessMaps[peerMap]
        hmap.remove_client(godotId)
        if hmap.clientPeers.is_empty():
            mapSnapshots[peerMap] = hmap.snapshot()
            hmap.teardown()
            hmap.queue_free()
            headlessMaps.erase(peerMap)
    free_peer_slot(idx)
    _update_rich_presence()
    _update_lobby_data()


func on_connected_to_server() -> void:
    localPeerId = multiplayer.get_unique_id()
    isActive = true
    var localIdx: int = alloc_peer_slot(localPeerId)
    peerNames[localIdx] = get_local_name()
    var currentMap: String = get_current_map()
    peerMaps[localIdx] = currentMap
    set_peer_timeout(1)
    worldState.start_item_tracking()
    _update_rich_presence()
    _log("Connected to server (id: %d)" % localPeerId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc(get_local_name(), localSteamID)
    if !currentMap.is_empty():
        sync_peer_map.rpc(currentMap)
    # _auto_load_game defers until world ID arrives.
    _request_world_id.rpc_id(1)


func on_connection_failed() -> void:
    _log("Connection failed")
    multiplayer.multiplayer_peer = null
    isActive = false


func on_server_disconnected() -> void:
    _log("Server disconnected")
    disconnect_session()

func on_lobby_created(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        _log("Lobby creation failed: %s" % response.get(&"error", "unknown"))
        return
    var lobbyID: String = response.get(&"data", { }).get(&"lobby_id", "")
    _log("Steam lobby created: %s" % lobbyID)
    _update_lobby_data()


func on_p2p_host_ready(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        _log("P2P host failed: %s" % response.get(&"error", "unknown"))
        return
    _log("P2P host listening for Steam peers")


func on_p2p_tunnel_ready(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        _log("P2P tunnel failed: %s" % response.get(&"error", "unknown"))
        return
    var tunnelPort: int = response.get(&"data", { }).get(&"tunnel_port", 0)
    if tunnelPort == 0:
        _log("P2P tunnel returned invalid port")
        return
    _log("P2P tunnel ready on 127.0.0.1:%d — connecting ENet" % tunnelPort)
    join_game("127.0.0.1", tunnelPort)

func get_local_name() -> String:
    if steamBridge.is_ready():
        return steamBridge.localSteamName
    return "Player_%d" % localPeerId


func get_peer_name(peerId: int) -> String:
    var idx: int = peer_idx(peerId)
    if idx >= 0:
        return peerNames[idx]
    return "Player_%d" % peerId


@rpc("any_peer", "call_remote", "reliable")
func sync_name(peerName: String, steamID: String = "") -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    var idx: int = alloc_peer_slot(senderId)
    var sanitized: String = sanitize_name(peerName)
    peerNames[idx] = sanitized
    if !steamID.is_empty() && _is_valid_steam_id(steamID):
        var prev: String = peerSteamIDs[idx]
        # Lock to first-set: rejects mid-session steamID swaps + prevents claiming another peer's ID.
        if prev.is_empty() && !_is_steam_id_claimed(steamID, idx):
            peerSteamIDs[idx] = steamID
            fetch_avatar(steamID)
            if isHost && !worldId.is_empty():
                send_character_to_client(senderId, steamID)
    if is_instance_valid(remoteNodes[idx]):
        remoteNodes[idx].displayName = sanitized
    _log("Peer %d name: %s (steam: %s)" % [senderId, sanitized, peerSteamIDs[idx]])


func _is_valid_steam_id(steamID: String) -> bool:
    if steamID.length() < 15 || steamID.length() > 20:
        return false
    for i: int in steamID.length():
        var c: int = steamID.unicode_at(i)
        if c < 48 || c > 57:
            return false
    return true


func _is_steam_id_claimed(steamID: String, exceptIdx: int) -> bool:
    for i: int in peerSteamIDs.size():
        if i == exceptIdx:
            continue
        if peerSteamIDs[i] == steamID:
            return true
    return false


func sanitize_name(rawName: String) -> String:
    var truncated: String = rawName.substr(0, 64)
    var clean: String = ""
    for i: int in truncated.length():
        var c: String = truncated[i]
        if c.unicode_at(0) >= 32:
            clean += c
    return clean if !clean.is_empty() else "Unknown"


func fetch_avatar(steamID: String) -> void:
    if steamID.is_empty() || steamID in avatarCache:
        return
    if !steamBridge.is_ready():
        return
    steamBridge.get_avatar_binary(steamID, on_avatar_binary_received)


func on_avatar_binary_received(steamID: String, w: int, h: int, rgba: PackedByteArray) -> void:
    if steamID.is_empty() || rgba.is_empty():
        return
    var img: Image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)
    avatarCache[steamID] = ImageTexture.create_from_image(img)


func get_peer_avatar(peerId: int) -> ImageTexture:
    var idx: int = peer_idx(peerId)
    if idx < 0:
        return null
    var steamID: String = peerSteamIDs[idx]
    if steamID.is_empty():
        return null
    if !avatarCache.has(steamID):
        return null
    return avatarCache[steamID]

func spawn_remote_player(peerId: int) -> void:
    var existingIdx: int = peer_idx(peerId)
    if existingIdx >= 0 && is_instance_valid(remoteNodes[existingIdx]):
        return
    if !is_peer_on_same_map(peerId):
        return
    var mapNode: Node = get_tree().current_scene
    if !is_instance_valid(mapNode):
        return
    if mapNode.get_node_or_null(PATH_CONTROLLER) == null:
        return

    playerState.clear_peer(peerId)

    var idx: int = alloc_peer_slot(peerId)
    var remote: Node3D = remotePlayerScene.instantiate()
    remote.name = "RemotePlayer_%d" % peerId
    remote.set_meta(&"peer_id", peerId)
    remote.tree_exiting.connect(on_remote_node_exiting.bind(peerId))
    mapNode.add_child(remote)
    remote.init_manager(self)
    var peerDisplayName: String = get_peer_name(peerId)
    remote.displayName = peerDisplayName
    remoteNodes[idx] = remote
    _log("Spawned remote player for peer %d (%s)" % [peerId, peerDisplayName])

    var cachedAppearance: Dictionary = cachedAppearances[idx]
    if !cachedAppearance.is_empty():
        _apply_cached_appearance(cachedAppearance, remote)
        cachedAppearances[idx] = {}
    var myAppearance: Dictionary = saveMirror.load_local_appearance()
    playerState.send_appearance_to(peerId, myAppearance.body, myAppearance.material)

    # Attachments must apply before equipment so set_active_weapon picks them up.
    var cachedAtt: Array = cachedAttachments[idx]
    if !cachedAtt.is_empty():
        remote.set_active_attachments(cachedAtt)
        cachedAttachments[idx] = []
    var cachedEq: String = cachedEquipment[idx]
    if !cachedEq.is_empty():
        remote.set_active_weapon(cachedEq)
        cachedEquipment[idx] = ""
    playerState.send_equipment_to(peerId, playerState.get_current_weapon_name())
    playerState.send_attachments_to(peerId, playerState.get_current_attachments())


func _apply_cached_appearance(cached: Dictionary, remote: Node3D) -> void:
    if !is_instance_valid(remote):
        return
    remote.set_appearance(cached.body, cached.material)


func on_remote_node_exiting(peerId: int) -> void:
    var idx: int = peer_idx(peerId)
    if idx >= 0:
        remoteNodes[idx] = null


func get_remote_player_node(peerId: int) -> Node3D:
    var idx: int = peer_idx(peerId)
    if idx < 0:
        return null
    return remoteNodes[idx]


func ensure_all_spawned() -> void:
    for i: int in peerGodotIds.size():
        var pid: int = peerGodotIds[i]
        if pid == -1 || pid == localPeerId:
            continue
        if !is_instance_valid(remoteNodes[i]):
            spawn_remote_player(pid)

func on_scene_changed() -> void:
    print("[TX] on_scene_changed begin")
    var wasOnMenu: bool = _wasOnMenu
    _wasOnMenu = _is_on_menu()
    _autoLoadInProgress = false
    # Menu-to-game transition skips the back-button free path.
    if is_instance_valid(coopUI) && coopUI.has_method(&"free_all_dialogs"):
        coopUI.free_all_dialogs()
    _maybe_customize_menu(get_tree().current_scene)
    if worldState != null:
        worldState.refresh_scene_cache()
    if aiState != null:
        aiState.refresh_scene_cache()
    if vehicleState != null:
        vehicleState.refresh_scene_cache()
    if !is_session_active():
        return

    var currentMap: String = get_current_map()
    var localIdx: int = peer_idx(localPeerId)
    if localIdx >= 0:
        peerMaps[localIdx] = currentMap

    if isHost && wasOnMenu && !_wasOnMenu:
        sync_game_start.rpc(_get_current_map_name())

    _despawn_off_map_peers()
    ensure_all_spawned()

    aiState.clear()
    _register_ai_pools()
    _reset_world_state_item_tracking()

    if isHost:
        _finalize_host_scene_transition(currentMap)

    if !currentMap.is_empty():
        sync_peer_map.rpc(currentMap)
    _update_rich_presence()
    _update_lobby_data()
    _log("Scene changed to %s" % currentMap)
    print("[TX] on_scene_changed end")


func _despawn_off_map_peers() -> void:
    for i: int in peerGodotIds.size():
        var pid: int = peerGodotIds[i]
        if pid == -1 || pid == localPeerId:
            continue
        if is_instance_valid(remoteNodes[i]) && !is_peer_on_same_map(pid):
            remoteNodes[i].queue_free()
            remoteNodes[i] = null


func _reset_world_state_item_tracking() -> void:
    if !worldState.trackingItems:
        return
    worldState.syncedItems.clear()
    worldState.consumedSyncIDs.clear()
    worldState.droppedItemHistory.clear()
    worldState.pendingDrops.clear()
    worldState.syncIdCounter = 0


## Host-only. 2s delay lets Unfreeze physics settle before captured positions are stable.
func _finalize_host_scene_transition(currentMap: String) -> void:
    var handoffSnap: Dictionary = _teardown_headless_map(currentMap)
    if !handoffSnap.is_empty():
        get_tree().create_timer(2.0).timeout.connect(_apply_handoff_state.bind(handoffSnap))
    if is_instance_valid(itemRegistrationTimer) && itemRegistrationTimer.time_left > 0:
        itemRegistrationTimer.timeout.disconnect(worldState.register_scene_items)
    itemRegistrationTimer = get_tree().create_timer(2.0)
    itemRegistrationTimer.timeout.connect(worldState.register_scene_items)


@rpc("any_peer", "call_remote", "reliable")
func notify_scene_loaded() -> void:
    if !isHost:
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    _log("Peer %d finished loading" % peerId)
    if is_peer_on_same_map(peerId):
        worldState.send_full_state(peerId)
        aiState.send_full_state(peerId)


# ModLoader runs past Menu.tscn load, so we modify the live instance instead of patching.
# Delegated to MenuCustomizer child — see [member menuCustomizer].
func _maybe_customize_menu(scene: Node) -> void:
    if is_instance_valid(menuCustomizer):
        menuCustomizer.maybe_customize(scene)


func _register_ai_pools() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var spawner: Node = scene.get_node_or_null(PATH_AI)
    if spawner != null:
        aiState.register_spawner_pools(spawner)

func _update_rich_presence() -> void:
    if !steamBridge.is_ready():
        return
    if !isActive:
        steamBridge.clear_rich_presence()
        return
    var playerCount: int = active_peer_count()
    var mapName: String = _get_current_map_name()
    var status: String = "Co-op (%d players)" % playerCount
    if !mapName.is_empty():
        status = "%s — %s" % [mapName, status]
    steamBridge.set_rich_presence("steam_display", "#Status")
    steamBridge.set_rich_presence("status", status)


func _update_lobby_data() -> void:
    if !steamBridge.is_ready() || !isHost:
        return
    var playerCount: int = active_peer_count()
    var mapName: String = _get_current_map_name()
    steamBridge.set_lobby_data("map", mapName)
    steamBridge.set_lobby_data("players", str(playerCount))
    var state: String = "menu" if _is_on_menu() else "in_game"
    steamBridge.set_lobby_data("state", state)


func _get_current_map_name() -> String:
    if !is_instance_valid(get_tree().current_scene):
        return ""
    var path: String = get_tree().current_scene.scene_file_path
    if path.is_empty():
        return ""
    return path.get_file().get_basename()


func migrate_solo_saves_if_needed() -> void:
    var migrated: int = saveMirror.migrate_solo_saves_if_needed()
    if migrated > 0:
        _log("Migrated %d solo save files to %s" % [migrated, saveMirror.SOLO_SAVES_DIR])


func _is_on_menu() -> bool:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return true
    var path: String = scene.scene_file_path
    return path.is_empty() || path == "res://Scenes/Menu.tscn"


func _auto_load_game() -> void:
    if isHost:
        return
    if !is_session_active():
        _log("Auto-load skipped — no active session")
        return
    if !_is_on_menu():
        _log("Auto-load skipped — already in game")
        return
    if _autoLoadInProgress:
        _log("Auto-load skipped — already in progress")
        return
    _autoLoadInProgress = true
    if !is_instance_valid(loader):
        _log("Auto-load failed — Loader not found")
        _autoLoadInProgress = false
        return
    var shelter: String = loader.ValidateShelter()
    if !shelter.is_empty():
        _log("Auto-load: continuing save (shelter: %s)" % shelter)
        loader.LoadScene(shelter)
    else:
        var diff: int = get_meta(&"new_world_difficulty", 1) as int
        var season: int = get_meta(&"new_world_season", 1) as int
        remove_meta(&"new_world_difficulty")
        remove_meta(&"new_world_season")
        _log("Auto-load: new game (difficulty=%d, season=%d)" % [diff, season])
        loader.NewGame(diff, season)
        loader.LoadScene("Cabin")


## Re-reads lobby state after ENet connects; host may have transitioned during tunnel setup.
func _recheck_host_state() -> void:
    if !steamBridge.is_ready():
        return
    if currentLobbyID.is_empty():
        return
    _recheckPending = true
    steamBridge.get_lobby_data(currentLobbyID, "state", _on_recheck_state)
    get_tree().create_timer(_RECHECK_TIMEOUT_SEC).timeout.connect(_on_recheck_timeout)


func _on_recheck_state(response: Dictionary) -> void:
    _recheckPending = false
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", {}) as Dictionary
    var hostState: String = data.get(&"value", "")
    if hostState == "in_game" && _is_on_menu():
        _log("Recheck: host is in-game — auto-loading")
        _client_start_load()


func _on_recheck_timeout() -> void:
    if !_recheckPending:
        return
    _recheckPending = false
    _log("Recheck timed out — staying on menu")


@rpc("authority", "call_remote", "reliable")
func sync_game_start(sceneName: String) -> void:
    _log("Host started game (%s) — auto-loading" % sceneName)
    _client_start_load()


## Host only. worldId must be set by the world picker UI first.


@rpc("any_peer", "call_remote", "reliable")
func _request_world_id() -> void:
    if !isHost:
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    # Send difficulty/season so client matches on fresh save.
    var diff: int = 1
    var season: int = 1
    var worldPath: String = saveMirror.get_save_path() + "World.tres"
    if FileAccess.file_exists(worldPath):
        var world: Resource = load(worldPath)
        if world != null:
            var diffVal: Variant = world.get(&"difficulty")
            if diffVal != null:
                diff = int(diffVal)
            var seasonVal: Variant = world.get(&"season")
            if seasonVal != null:
                season = int(seasonVal)
    _receive_world_id.rpc_id(peerId, worldId, diff, season)


@rpc("authority", "call_remote", "reliable")
func _receive_world_id(hostWorldId: String, hostDifficulty: int, hostSeason: int) -> void:
    if !saveMirror.sanitize_path_component(hostWorldId):
        _log("Invalid worldId from host: %s" % hostWorldId)
        return
    worldId = hostWorldId
    var localSteamId: String = steamBridge.localSteamID if steamBridge.is_ready() else str(localPeerId)
    saveMirror.apply_save_paths("user://coop/%s/" % worldId, "user://coop/%s/players/%s/" % [worldId, localSteamId])
    set_meta(&"new_world_difficulty", hostDifficulty)
    set_meta(&"new_world_season", hostSeason)
    _log("Client new_world meta: diff=%d season=%d" % [hostDifficulty, hostSeason])
    if pendingAutoJoin:
        pendingAutoJoin = false
        _client_start_load.call_deferred()
    elif _is_on_menu():
        # Direct-connect has no lobby; skip recheck.
        if currentLobbyID.is_empty():
            _client_start_load.call_deferred()
        else:
            _recheck_host_state()


## Gates scene load behind the character-creation picker so client confirms before entry.
func _client_start_load() -> void:
    if !is_instance_valid(coopUI):
        if !saveMirror.has_local_appearance():
            saveMirror.save_local_appearance(appearance.get_defaults())
        _auto_load_game()
        return
    coopUI.show_character_picker(_on_client_picker_confirm, _on_client_picker_cancel)


func _on_client_picker_confirm(_entry: Dictionary = {}) -> void:
    if !saveMirror.has_local_appearance():
        saveMirror.save_local_appearance(appearance.get_defaults())
    _auto_load_game()


func _on_client_picker_cancel() -> void:
    _log("Client cancelled character picker — disconnecting")
    disconnect_session()


func send_character_to_host() -> void:
    if isHost:
        return
    if !is_instance_valid(loader):
        return
    var charPath: String = saveMirror.get_player_save_path() + "Character.tres"
    if !FileAccess.file_exists(charPath):
        return
    var fileData: PackedByteArray = FileAccess.get_file_as_bytes(charPath)
    if fileData.is_empty():
        return
    var localSteamId: String = steamBridge.localSteamID if steamBridge.is_ready() else str(localPeerId)
    _receive_client_character.rpc_id(1, localSteamId, fileData)
    _log("Sent character to host (%d bytes)" % fileData.size())


# Steam ID is looked up from peerSteamIDs; not trusted from RPC args.
@rpc("any_peer", "call_remote", "reliable")
func _receive_client_character(clientSteamId: String, fileData: PackedByteArray) -> void:
    if !isHost:
        return
    var senderId: int = multiplayer.get_remote_sender_id()
    var senderIdx: int = peer_idx(senderId)
    var trustedSteamId: String = peerSteamIDs[senderIdx] if senderIdx >= 0 else ""
    if trustedSteamId.is_empty() || fileData.is_empty():
        return
    if fileData.size() > 1048576:
        _log("Character file too large from peer %d (%d bytes)" % [senderId, fileData.size()])
        return
    var dir: String = "user://coop/%s/players/%s/" % [worldId, trustedSteamId]
    if !DirAccess.dir_exists_absolute(dir):
        DirAccess.make_dir_recursive_absolute(dir)
    var filePath: String = dir + "Character.tres"
    var file: FileAccess = FileAccess.open(filePath, FileAccess.WRITE)
    if file != null:
        file.store_buffer(fileData)
        file.close()
        _log("Stored character for %s (%d bytes)" % [clientSteamId, fileData.size()])


func send_character_to_client(peerId: int, clientSteamId: String) -> void:
    if !isHost:
        return
    var filePath: String = "user://coop/%s/players/%s/Character.tres" % [worldId, clientSteamId]
    if !FileAccess.file_exists(filePath):
        _receive_host_character.rpc_id(peerId, PackedByteArray())
        return
    var fileData: PackedByteArray = FileAccess.get_file_as_bytes(filePath)
    _receive_host_character.rpc_id(peerId, fileData)
    _log("Sent stored character to peer %d (%d bytes)" % [peerId, fileData.size()])


# Default param prevents RPC arg-count error: Godot collapses empty PackedByteArray args.
@rpc("authority", "call_remote", "reliable")
func _receive_host_character(fileData: PackedByteArray = PackedByteArray()) -> void:
    if !is_instance_valid(loader):
        return
    if fileData.is_empty():
        _log("No stored character on host — starting fresh")
        return
    var dir: String = saveMirror.get_player_save_path()
    if !DirAccess.dir_exists_absolute(dir):
        DirAccess.make_dir_recursive_absolute(dir)
    var filePath: String = dir + "Character.tres"
    var file: FileAccess = FileAccess.open(filePath, FileAccess.WRITE)
    if file != null:
        file.store_buffer(fileData)
        file.close()
        _log("Received character from host (%d bytes)" % fileData.size())

func get_current_map() -> String:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return ""
    return scene.scene_file_path


func is_peer_on_same_map(peerId: int) -> bool:
    var localMap: String = get_current_map()
    if localMap.is_empty():
        return false
    var idx: int = peer_idx(peerId)
    if idx < 0:
        return false
    return peerMaps[idx] == localMap


@rpc("any_peer", "call_remote", "reliable")
func sync_peer_map(mapPath: String) -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    var senderIdx: int = alloc_peer_slot(senderId)
    var oldMap: String = peerMaps[senderIdx]
    peerMaps[senderIdx] = mapPath
    var localMap: String = get_current_map()
    _log("Peer %d map: %s" % [senderId, mapPath])

    if mapPath == localMap:
        spawn_remote_player.call_deferred(senderId)
        if isHost:
            worldState.send_full_state.call_deferred(senderId)
            aiState.send_full_state.call_deferred(senderId)
            _teardown_headless_map(mapPath)
    elif oldMap == localMap:
        if is_instance_valid(remoteNodes[senderIdx]):
            remoteNodes[senderIdx].queue_free()
        remoteNodes[senderIdx] = null
        playerState.clear_peer(senderId)

    if isHost:
        _update_headless_maps(senderId, oldMap, mapPath)


# Menu audio bleeds through SubViewport into host's Master bus; skip non-gameplay scenes.
const _HEADLESS_SKIP_SCENES: Array[String] = [
    "res://Scenes/Menu.tscn",
    "res://Scenes/Death.tscn",
]


func _is_headless_eligible_map(mapPath: String) -> bool:
    return !(mapPath in _HEADLESS_SKIP_SCENES)


func _update_headless_maps(peerId: int, oldMap: String, newMap: String) -> void:
    var localMap: String = get_current_map()

    if !oldMap.is_empty() && oldMap != localMap && oldMap in headlessMaps:
        var oldHmap: Node = headlessMaps[oldMap]
        oldHmap.remove_client(peerId)
        if oldHmap.clientPeers.is_empty():
            mapSnapshots[oldMap] = oldHmap.snapshot()
            oldHmap.teardown()
            oldHmap.queue_free()
            headlessMaps.erase(oldMap)
            _log("Headless map freed: %s (snapshot saved)" % oldMap)

    # Threaded setup(): restore+start deferred to setup_finished so main thread isn't blocked.
    if !newMap.is_empty() && newMap != localMap && _is_headless_eligible_map(newMap):
        if newMap not in headlessMaps:
            var hmap: Node = HeadlessMapScript.new()
            hmap.name = "Headless_%s" % newMap.get_file().get_basename()
            add_child(hmap)
            hmap.init_manager(self)
            if !hmap.setup(newMap):
                hmap.queue_free()
                return
            headlessMaps[newMap] = hmap
            hmap.setup_finished.connect(
                _on_headless_setup_finished.bind(newMap),
                CONNECT_ONE_SHOT
            )
            _log("Headless map queued (threaded load): %s" % newMap)
        headlessMaps[newMap].add_client(peerId)


## Applies pending snapshot restore and starts the SubViewport after threaded scene load.
func _on_headless_setup_finished(success: bool, mapPath: String) -> void:
    if mapPath not in headlessMaps:
        return
    var hmap: Node = headlessMaps[mapPath]
    if !success:
        _log("Headless map setup failed: %s" % mapPath)
        if is_instance_valid(hmap):
            hmap.queue_free()
        headlessMaps.erase(mapPath)
        return
    if !is_instance_valid(hmap):
        return
    if mapPath in mapSnapshots:
        hmap.restore(mapSnapshots[mapPath])
        mapSnapshots.erase(mapPath)
    hmap.start()
    _log("Headless map ready: %s" % mapPath)


func _teardown_headless_map(mapPath: String) -> Dictionary:
    if mapPath not in headlessMaps:
        return {}
    var hmap: Node = headlessMaps[mapPath]
    var snap: Dictionary = hmap.snapshot()
    hmap.teardown()
    hmap.queue_free()
    headlessMaps.erase(mapPath)
    _log("Headless map transferred to real scene: %s" % mapPath)
    return snap


func _apply_handoff_state(snap: Dictionary) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var doors: Dictionary = snap.get(&"doors", {}) as Dictionary
    for doorPath: String in doors:
        var door: Node = scene.get_node_or_null(NodePath(doorPath))
        if !is_instance_valid(door) || !(door is Door):
            continue
        var state: Dictionary = doors[doorPath]
        door.isOpen = state.get(&"isOpen", false)
        door.locked = state.get(&"locked", false)
        if door.isOpen:
            door.animationTime = 4.0
    var switches: Dictionary = snap.get(&"switches", {}) as Dictionary
    for switchPath: String in switches:
        var sw: Node = scene.get_node_or_null(NodePath(switchPath))
        if !is_instance_valid(sw) || !sw.has_method(&"Activate"):
            continue
        var active: bool = switches[switchPath]
        if active && !sw.active:
            sw.Activate()
        elif !active && sw.active:
            sw.Deactivate()
    # LootSimulation was skipped in SubViewport, so transfer items from snapshot.
    var items: Array = snap.get(&"items", []) as Array
    var spawnedCount: int = 0
    for entry: Dictionary in items:
        var itemFile: String = entry.get(&"file", "")
        if itemFile.is_empty():
            continue
        var packed: PackedScene = Database.get(itemFile)
        if packed == null:
            continue
        var pickup: Node3D = packed.instantiate()
        scene.add_child(pickup)
        pickup.global_position = entry.get(&"pos", Vector3.ZERO)
        pickup.global_rotation = entry.get(&"rot", Vector3.ZERO)
        var slotData: Resource = entry.get(&"slotData")
        if slotData != null && pickup.get(&"slotData") != null:
            pickup.slotData.Update(slotData)
        # Freeze so physics doesn't jitter snapshot items (matches Loader.gd shelter-load).
        if pickup.has_method(&"Freeze"):
            pickup.Freeze()
        if pickup.has_method(&"UpdateAttachments"):
            pickup.UpdateAttachments()
        spawnedCount += 1
    _log("Handoff applied: %d doors, %d switches, %d items" % [doors.size(), switches.size(), spawnedCount])


func forward_position_to_headless(peerId: int, pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    var idx: int = peer_idx(peerId)
    if idx < 0:
        return
    var peerMap: String = peerMaps[idx]
    if peerMap.is_empty() || peerMap not in headlessMaps:
        return
    headlessMaps[peerMap].update_client_position(peerId, pos, camPos, rot, flags)

# Backtick toggles mouse capture in editor builds.
func _input(event: InputEvent) -> void:
    if !DEBUG:
        return
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if event.keycode == KEY_QUOTELEFT:
        var current: Input.MouseMode = Input.get_mouse_mode()
        if current == Input.MOUSE_MODE_CAPTURED || current == Input.MOUSE_MODE_CONFINED_HIDDEN:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
        else:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func force_windowed() -> void:
    var prefs: Preferences = Preferences.Load() as Preferences
    if prefs == null:
        prefs = Preferences.new()
    prefs.displayMode = 2
    prefs.windowSize = 3
    prefs.Save()


func set_peer_timeout(peerId: int) -> void:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if !(peer is ENetMultiplayerPeer):
        return
    var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer
    var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
    if enetPeer != null:
        enetPeer.set_timeout(0, 30000, 60000)


func is_session_active() -> bool:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if peer == null || peer is OfflineMultiplayerPeer:
        return false
    return peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func get_setting(key: String, fallback: Variant = null) -> Variant:
    return settings.get(key, fallback)


func set_setting(key: String, value: Variant) -> void:
    if !isHost:
        if worldState != null && worldState.has_method(&"request_setting_change"):
            worldState.request_setting_change.rpc_id(1, key, value)
        return
    settings[key] = value
    if worldState != null && worldState.has_method(&"broadcast_settings"):
        worldState.broadcast_settings.rpc(settings)


## Returns true if routed through co-op; false means caller should run target.Interact() locally.
## Dispatch logic lives in [code]coop_interact_router.gd[/code] (see member [member _interactRouter]).
func dispatch_interact(target: Node) -> bool:
    return _interactRouter.dispatch(self, target)


func get_local_ip() -> String:
    for addr: String in IP.get_local_addresses():
        if addr.begins_with("127.") || addr.begins_with("::") || ":" in addr:
            continue
        return addr
    return "127.0.0.1"


func get_sharable_addresses() -> Array[String]:
    var out: Array[String] = []
    for addr: String in IP.get_local_addresses():
        if addr.begins_with("127.") || addr.begins_with("169.254."):
            continue
        if ":" in addr:
            continue
        out.append(addr)
    if out.is_empty():
        out.append("127.0.0.1")
    return out


func find_remote_root(node: Node) -> Node3D:
    var current: Node = node
    while current != null && is_instance_valid(current):
        if current.is_in_group(&"CoopRemote"):
            if current.has_meta(&"peer_id"):
                return current as Node3D
        current = current.get_parent()
    return null


func _log(msg: String) -> void:
    print("[CoopManager] %s" % msg)
