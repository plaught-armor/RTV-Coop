## Main mod autoload for the Road to Vostok co-op mod.
## Manages peer lifecycle, script patching, remote player spawning,
## Steam integration, and scene change detection. Persists across scene transitions.
## All connections go through Steam (lobbies + P2P tunnel). ENet direct-connect
## is available behind [member DEBUG] for local development only.
extends Node

## Default ENet server port (used internally by the P2P tunnel).
const DEFAULT_PORT: int = 9050
## Maximum number of clients that can connect to the host.
const MAX_CLIENTS: int = 3
## Debug mode — enabled automatically when running from the editor.
var DEBUG: bool = OS.has_feature("editor")
## Whether the co-op panel is open (blocks mouse input on the controller).
var panelOpen: bool = false
## The local peer's multiplayer ID. 0 when not connected.
var localPeerId: int = 0
## Whether this instance is the host (server).
var isHost: bool = false
## Whether a multiplayer session is active (host or client).
var isActive: bool = false
## Connected peer IDs. Source of truth for who is in the session.
var connectedPeers: PackedInt32Array = []
## Spawned remote player nodes, keyed by peer ID. Only contains live nodes.
var remoteNodes: Dictionary[int, Node3D] = { }
## Appearance entries received from peers before their [RemotePlayer] node
## existed. Drained when [method spawn_remote_player] instantiates the peer.
var cachedAppearances: Dictionary[int, Dictionary] = { }
## Weapon-name entries received from peers before their [RemotePlayer] node
## existed. Drained the same way as [member cachedAppearances].
var cachedEquipment: Dictionary[int, String] = { }
## Maps multiplayer peer ID -> display name (Steam persona or fallback).
var peerNames: Dictionary[int, String] = { }
## Maps multiplayer peer ID -> Steam ID string.
var peerSteamIDs: Dictionary[int, String] = { }
## Cached avatar textures keyed by Steam ID string.
var avatarCache: Dictionary[String, ImageTexture] = { }
## Maps multiplayer peer ID -> scene file path of the map they are on.
var peerMaps: Dictionary[int, String] = { }
## Headless map simulations keyed by map scene path. Host only.
var headlessMaps: Dictionary[String, Node] = {}
## Persisted snapshots of headless maps after teardown.
var mapSnapshots: Dictionary[String, Dictionary] = {}
## Host-owned session settings broadcast to every peer. Used by patches that
## want a single tunable knob across the whole session (e.g. simulation day
## rate, friendly fire). Update via [method set_setting] on the host.
var settings: Dictionary = {
    "day_rate_multiplier": 1.0,
    "night_rate_multiplier": 1.0,
}
## Reference to the [code]PlayerState[/code] child node handling position sync.
var playerState: Node = null
## Reference to the [code]WorldState[/code] child node handling world sync.
var worldState: Node = null
## Reference to the [code]AIState[/code] child node handling AI replication.
var aiState: Node = null
## Reference to the [code]SteamBridge[/code] child node for Steam helper IPC.
var steamBridge: Node = null
## Cached reference to /root/Loader autoload.
var loader: Node = null
## Reference to the co-op UI panel.
var coopUI: Control = null
var _pendingHostUseSteam: bool = true

## Consolidated preloads — children access these via [code]_cm.PropertyName[/code].
var remotePlayerScene: PackedScene = preload("res://mod/presentation/remote_player.tscn")
var PlayerStateScript: Script = preload("res://mod/network/player_state.gd")
var SlotSerializerScript: Script = preload("res://mod/network/slot_serializer.gd")
var HeadlessMapScript: Script = preload("res://mod/network/headless_map.gd")
## Cached before take_over_path — avoids circular extends after path redirect.
var PickupPatchScript: Script = preload("res://mod/patches/pickup_patch.gd")
var AppearanceScript: Script = preload("res://mod/network/appearance.gd")
var audioLibrary: AudioLibrary = preload("res://Resources/AudioLibrary.tres")
var gd: GameData = preload("res://Resources/GameData.tres")
var lastScenePath: String = ""
## Timer for deferred register_scene_items after scene change.
var itemRegistrationTimer: SceneTreeTimer = null
## Active co-op world ID. Empty when not hosting/joined.
var worldId: String = ""
## Check scene every 60 physics frames (~0.5s at 120Hz).
const SCENE_CHECK_FRAMES: int = 60
## Set when lobby state says host is in-game; consumed in on_connected_to_server.
var pendingAutoJoin: bool = false
## Set while we were in any coop session (host or client). Used to suppress
## mirror_user_to_solo on the subsequent menu return — client user:// may
## hold stale .tres files written by vanilla save paths during transitions,
## and we don't want those promoted into the solo save.
var _wasInCoop: bool = false
## Lobby ID of the currently joined lobby (for reading lobby metadata).
var currentLobbyID: String = ""
## Tracks previous scene to detect menu→game transitions.
var _wasOnMenu: bool = true
## Prevents double _auto_load_game calls during async scene loading.
var _autoLoadInProgress: bool = false
## Set while waiting on async lobby state recheck.
var _recheckPending: bool = false
## Timeout for async lobby state recheck callback (seconds).
const _RECHECK_TIMEOUT_SEC: float = 5.0


func _ready() -> void:
    set_meta(&"is_coop_manager", true)
    if DEBUG:
        force_windowed()

    register_patches()
    loader = get_node_or_null("/root/Loader")

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

    steamBridge = SteamBridgeScript.new()
    steamBridge.name = "SteamBridge"
    add_child(steamBridge)
    steamBridge.init_manager(self)
    # Kick off the helper launch immediately so it boots in parallel with UI
    # setup. Previously this was deferred to the next frame, which added an
    # unnecessary ~16ms and blocked the helper's TCP handshake behind UI work.
    steamBridge.launch()

    var uiLayer: CanvasLayer = CanvasLayer.new()
    uiLayer.name = "CoopUILayer"
    uiLayer.layer = 100
    add_child(uiLayer)
    coopUI = load("res://mod/ui/coop_ui.gd").new()
    coopUI.name = "CoopUI"
    uiLayer.add_child(coopUI)
    coopUI.init_manager(self)

    var coopHUD: VBoxContainer = load("res://mod/ui/coop_hud.gd").new()
    coopHUD.name = "CoopHUD"
    uiLayer.add_child(coopHUD)
    coopHUD.init_manager(self)

    multiplayer.peer_connected.connect(on_peer_connected)
    multiplayer.peer_disconnected.connect(on_peer_disconnected)
    multiplayer.connected_to_server.connect(on_connected_to_server)
    multiplayer.connection_failed.connect(on_connection_failed)
    multiplayer.server_disconnected.connect(on_server_disconnected)

    # One-time migration: move pre-mod solo saves out of user:// root so they
    # don't get clobbered when the player hosts a coop world.
    migrate_solo_saves_if_needed()

    inject_manager.call_deferred()
    _register_ai_pools.call_deferred()
    _log("Initialized (debug: %s)" % str(DEBUG))


func _physics_process(_delta: float) -> void:
    # Poll Steam readiness every 30 frames (~0.25s) so the MP submenu's status
    # label and button-disabled state reflect current helper state.
    if Engine.get_physics_frames() % 30 == 0:
        _update_mp_status()

    if Engine.get_physics_frames() % SCENE_CHECK_FRAMES != 0:
        return

    if !is_instance_valid(get_tree().current_scene):
        return
    var currentPath: String = get_tree().current_scene.scene_file_path
    if currentPath != lastScenePath:
        lastScenePath = currentPath
        call_deferred("on_scene_changed")
    elif isActive:
        ensure_all_spawned()


## Updates the MP submenu's Steam status label and button enable state.
## No-op if the submenu hasn't been built yet or we're not on the main menu.
func _update_mp_status() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var submenu: Node = scene.get_node_or_null("CoopMPSubmenu")
    if submenu == null:
        return
    var hostBtn: Button = submenu.find_child("HostBtn", true, false) as Button
    var browseBtn: Button = submenu.find_child("BrowseBtn", true, false) as Button
    var ready: bool = is_instance_valid(steamBridge) && steamBridge.is_ready() && steamBridge.ownsGame
    if hostBtn != null:
        hostBtn.disabled = !ready
    if browseBtn != null:
        browseBtn.disabled = !ready


## Applies [code]take_over_path[/code] patches to game scripts.
func register_patches() -> void:
    var patches: Array[PackedStringArray] = [
        ["res://mod/patches/controller_patch.gd", "res://Scripts/Controller.gd"],
        ["res://mod/patches/interactor_patch.gd", "res://Scripts/Interactor.gd"],
        ["res://mod/patches/transition_patch.gd", "res://Scripts/Transition.gd"],
        ["res://mod/patches/pickup_patch.gd", "res://Scripts/Pickup.gd"],
        ["res://mod/patches/interface_patch.gd", "res://Scripts/Interface.gd"],
        ["res://mod/patches/loot_simulation_patch.gd", "res://Scripts/LootSimulation.gd"],
        ["res://mod/patches/ai_spawner_patch.gd", "res://Scripts/AISpawner.gd"],
        ["res://mod/patches/ai_patch.gd", "res://Scripts/AI.gd"],
        ["res://mod/patches/grenade_rig_patch.gd", "res://Scripts/GrenadeRig.gd"],
        ["res://mod/patches/knife_rig_patch.gd", "res://Scripts/KnifeRig.gd"],
        ["res://mod/patches/explosion_patch.gd", "res://Scripts/Explosion.gd"],
        ["res://mod/patches/character_patch.gd", "res://Scripts/Character.gd"],
        ["res://mod/patches/mine_patch.gd", "res://Scripts/Mine.gd"],
        ["res://mod/patches/loader_patch.gd", "res://Scripts/Loader.gd"],
        ["res://mod/patches/settings_patch.gd", "res://Scripts/Settings.gd"],
        ["res://mod/patches/layouts_patch.gd", "res://Scripts/Layouts.gd"],
        ["res://mod/patches/furniture_patch.gd", "res://Scripts/Furniture.gd"],
        ["res://mod/patches/fish_pool_patch.gd", "res://Scripts/FishPool.gd"],
        ["res://mod/patches/event_system_patch.gd", "res://Scripts/EventSystem.gd"],
        ["res://mod/patches/trader_patch.gd", "res://Scripts/Trader.gd"],
        ["res://mod/patches/simulation_patch.gd", "res://Scripts/Simulation.gd"],
    ]
    for pair: PackedStringArray in patches:
        var patch: Script = load(pair[0])
        patch.reload()
        patch.take_over_path(pair[1])
    _log("Patches registered (%d)" % patches.size())


# ---------- Peer Lifecycle ----------


## Creates an ENet server and a Steam P2P listen socket + lobby.
## Starts the ENet server. Peers can connect immediately. World/save setup
## is deferred until [method finalize_host] after the host picks a world.
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
    peerNames[localPeerId] = steamBridge.localSteamName if steamBridge.is_ready() else "Host"
    peerMaps[localPeerId] = get_current_map()

    if useSteam && steamBridge.is_ready():
        steamBridge.start_p2p_host(on_p2p_host_ready, port)
        steamBridge.create_lobby(MAX_CLIENTS + 1, on_lobby_created)

    _wasInCoop = true
    _log("Hosting on port %d (id: %d, steam: %s)" % [port, localPeerId, str(useSteam)])
    return true


## Sets up world save paths and item tracking after the host picks a world.
func finalize_host() -> void:
    worldState.start_item_tracking()
    _setup_save_paths()
    _update_rich_presence()


## Legacy wrapper — starts hosting and finalizes in one call.
func host_game(port: int = DEFAULT_PORT, useSteam: bool = true) -> void:
    if start_hosting(port, useSteam):
        finalize_host()


## Connects to a host at [param address]:[param port] as a client.
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
    # Set generous timeout before assigning peer — handshake needs time over P2P relay
    var serverPeer: ENetPacketPeer = peer.get_peer(1)
    if serverPeer != null:
        serverPeer.set_timeout(0, 30000, 60000)
    multiplayer.multiplayer_peer = peer
    isHost = false
    _log("Connecting to %s:%d" % [address, port])


## Tears down the multiplayer session and cleans up all remote players.
func disconnect_session() -> void:
    if !is_session_active():
        return

    # Stop subsystems FIRST so no in-flight RPCs or tracking writes fire
    # after we start cleaning up file state.
    worldState.stop_item_tracking()

    # Mirror final state to the world dir BEFORE nulling the peer — any late
    # save events from the current frame still have valid state. Host-only
    # since only the host has authoritative saves in user://.
    var wasHost: bool = isHost
    if wasHost && !worldId.is_empty():
        mirror_user_to_world()

    # Now tear down networking state.
    for peerId: int in connectedPeers:
        playerState.clear_peer(peerId)
    for peerId: int in remoteNodes:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
    remoteNodes.clear()
    connectedPeers.clear()
    peerNames.clear()
    peerSteamIDs.clear()
    peerMaps.clear()
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

    # Wipe user:// for BOTH host and client — clients may have stale .tres
    # files written by vanilla save paths during transitions, which would
    # otherwise promote into solo on next menu return.
    wipe_user_saves()
    clear_active_world()
    _reset_save_paths()
    steamBridge.leave_lobby()
    steamBridge.clear_rich_presence()
    _log("Disconnected (was host: %s)" % str(wasHost))

# ---------- Signal Handlers ----------


func on_peer_connected(peerId: int) -> void:
    _log("Peer connected: %d" % peerId)
    connectedPeers.append(peerId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc_id(peerId, get_local_name(), localSteamID)
    set_peer_timeout(peerId)
    _update_rich_presence()
    _update_lobby_data()
    # Send our current map so peer knows where we are
    var currentMap: String = get_current_map()
    if !currentMap.is_empty():
        sync_peer_map.rpc_id(peerId, currentMap)
    # Don't spawn remote player yet — wait for sync_peer_map from peer
    # to confirm they're on the same map


func on_peer_disconnected(peerId: int) -> void:
    _log("Peer disconnected: %d" % peerId)
    var idx: int = connectedPeers.find(peerId)
    if idx >= 0:
        connectedPeers.remove_at(idx)
    playerState.clear_peer(peerId)
    peerNames.erase(peerId)
    peerSteamIDs.erase(peerId)
    cachedAppearances.erase(peerId)
    cachedEquipment.erase(peerId)
    var peerMap: String = peerMaps.get(peerId, "")
    peerMaps.erase(peerId)
    # Remove from headless map if applicable
    if isHost && !peerMap.is_empty() && peerMap in headlessMaps:
        var hmap: Node = headlessMaps[peerMap]
        hmap.remove_client(peerId)
        if hmap.clientPeers.is_empty():
            mapSnapshots[peerMap] = hmap.snapshot()
            hmap.teardown()
            hmap.queue_free()
            headlessMaps.erase(peerMap)
    _update_rich_presence()
    _update_lobby_data()
    if peerId in remoteNodes:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
        remoteNodes.erase(peerId)


func on_connected_to_server() -> void:
    localPeerId = multiplayer.get_unique_id()
    isActive = true
    peerNames[localPeerId] = get_local_name()
    var currentMap: String = get_current_map()
    peerMaps[localPeerId] = currentMap
    set_peer_timeout(1) # Server is always peer ID 1
    worldState.start_item_tracking()
    _update_rich_presence()
    _wasInCoop = true
    _log("Connected to server (id: %d)" % localPeerId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc(get_local_name(), localSteamID)
    if !currentMap.is_empty():
        sync_peer_map.rpc(currentMap)
    # Request world ID from host — _auto_load_game is deferred until response arrives
    _request_world_id.rpc_id(1)


func on_connection_failed() -> void:
    _log("Connection failed")
    multiplayer.multiplayer_peer = null
    isActive = false


func on_server_disconnected() -> void:
    _log("Server disconnected")
    disconnect_session()

# ---------- Steam Callbacks ----------


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

# ---------- Name Sync ----------


## Returns the local player's display name.
func get_local_name() -> String:
    if steamBridge.is_ready():
        return steamBridge.localSteamName
    return "Player_%d" % localPeerId


## Returns the display name for [param peerId], or a fallback.
func get_peer_name(peerId: int) -> String:
    return peerNames.get(peerId, "Player_%d" % peerId)


## RPC: receives a peer's display name and Steam ID.
@rpc("any_peer", "call_remote", "reliable")
func sync_name(peerName: String, steamID: String = "") -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    var sanitized: String = sanitize_name(peerName)
    peerNames[senderId] = sanitized
    if !steamID.is_empty():
        peerSteamIDs[senderId] = steamID
        fetch_avatar(steamID)
        # Send stored character to joining client if we have one
        if isHost && !worldId.is_empty():
            send_character_to_client(senderId, steamID)
    # Update display name on existing remote player node
    if senderId in remoteNodes:
        var remote: Node3D = remoteNodes[senderId]
        if is_instance_valid(remote):
            remote.displayName = sanitized
    _log("Peer %d name: %s (steam: %s)" % [senderId, sanitized, steamID])


func sanitize_name(rawName: String) -> String:
    var truncated: String = rawName.substr(0, 64)
    var clean: String = ""
    for i: int in truncated.length():
        var c: String = truncated[i]
        if c.unicode_at(0) >= 32:
            clean += c
    return clean if !clean.is_empty() else "Unknown"


## Fetches and caches a Steam avatar by Steam ID. Skips if already cached.
## Uses binary transfer (raw RGBA bytes) to avoid base64 overhead.
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


## Returns the cached avatar texture for a peer, or null.
func get_peer_avatar(peerId: int) -> ImageTexture:
    var steamID: String = peerSteamIDs.get(peerId, "")
    if steamID.is_empty():
        return null
    return avatarCache.get(steamID)

# ---------- Remote Player Management ----------


func spawn_remote_player(peerId: int) -> void:
    if peerId in remoteNodes:
        return
    if !is_peer_on_same_map(peerId):
        return
    var mapNode: Node = get_tree().current_scene
    if !is_instance_valid(mapNode):
        return
    if mapNode.get_node_or_null("Core/Controller") == null:
        return

    playerState.clear_peer(peerId)

    var remote: Node3D = remotePlayerScene.instantiate()
    remote.name = "RemotePlayer_%d" % peerId
    remote.set_meta(&"peer_id", peerId)
    remote.tree_exiting.connect(on_remote_node_exiting.bind(peerId))
    mapNode.add_child(remote)
    remote.init_manager(self)
    # Set display name from peer registry
    var peerDisplayName: String = get_peer_name(peerId)
    remote.displayName = peerDisplayName
    remoteNodes[peerId] = remote
    _log("Spawned remote player for peer %d (%s)" % [peerId, peerDisplayName])

    # Exchange appearance: apply any cached remote entry, then hand the peer our
    # local choice so they can swap their placeholder model on their end.
    if peerId in cachedAppearances:
        var cached: Dictionary = cachedAppearances[peerId]
        remote.set_appearance(cached.body, cached.material)
        cachedAppearances.erase(peerId)
    var myAppearance: Dictionary = load_local_appearance()
    playerState.send_appearance_to(peerId, myAppearance.body, myAppearance.material)

    # Equipment: apply cached + push our current weapon to the new peer.
    if peerId in cachedEquipment:
        remote.set_active_weapon(cachedEquipment[peerId])
        cachedEquipment.erase(peerId)
    playerState.send_equipment_to(peerId, playerState.get_current_weapon_name())


func on_remote_node_exiting(peerId: int) -> void:
    remoteNodes.erase(peerId)


func get_remote_player_node(peerId: int) -> Node3D:
    return remoteNodes.get(peerId)


func ensure_all_spawned() -> void:
    for peerId: int in connectedPeers:
        if peerId not in remoteNodes:
            spawn_remote_player(peerId)

# ---------- Scene Change Handling ----------


func on_scene_changed() -> void:
    print("[TX] on_scene_changed begin")
    var wasOnMenu: bool = _wasOnMenu
    _wasOnMenu = _is_on_menu()
    _autoLoadInProgress = false
    inject_manager()
    # Refresh network-layer scene caches — both world_state and ai_state
    # hold refs to current_scene / Core/Controller / UI Interface / etc.
    # Repopulate once per transition; RPC handlers read typed vars
    # instead of walking get_tree().current_scene on every call.
    if worldState != null:
        worldState.refresh_scene_cache()
    if aiState != null:
        aiState.refresh_scene_cache()
    if !is_session_active():
        return
    var currentMap: String = get_current_map()
    peerMaps[localPeerId] = currentMap
    # Host transitioned from menu to in-game — tell waiting clients to load
    if isHost && wasOnMenu && !_wasOnMenu:
        var mapName: String = _get_current_map_name()
        sync_game_start.rpc(mapName)
    # Despawn peers on other maps. Two-phase to avoid mutating during iteration.
    var toErase: Array[int] = []
    for peerId: int in remoteNodes:
        if !is_peer_on_same_map(peerId):
            toErase.append(peerId)
    for peerId: int in toErase:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
        remoteNodes.erase(peerId)
    ensure_all_spawned()
    # Reset tracking state from the PREVIOUS scene before registering the new one
    aiState.clear()
    _register_ai_pools()
    if worldState.trackingItems:
        worldState.syncedItems.clear()
        worldState.consumedSyncIDs.clear()
        worldState.droppedItemHistory.clear()
        worldState.pendingDrops.clear()
        worldState.syncIdCounter = 0
    if isHost:
        # If we arrived at a map that was running headlessly, extract + transfer state
        var handoffSnap: Dictionary = _teardown_headless_map(currentMap)
        if !handoffSnap.is_empty():
            get_tree().create_timer(2.0).timeout.connect(_apply_handoff_state.bind(handoffSnap))
        # Cancel any previous timer from a rapid scene re-entry
        if is_instance_valid(itemRegistrationTimer) && itemRegistrationTimer.time_left > 0:
            itemRegistrationTimer.timeout.disconnect(worldState.register_scene_items)
        # Delay 2s so Unfreeze physics settles before capturing positions
        itemRegistrationTimer = get_tree().create_timer(2.0)
        itemRegistrationTimer.timeout.connect(worldState.register_scene_items)
    # Broadcast our new map to all peers
    if !currentMap.is_empty():
        sync_peer_map.rpc(currentMap)
    _update_rich_presence()
    _update_lobby_data()
    _log("Scene changed to %s" % currentMap)
    print("[TX] on_scene_changed end")


## Client tells host they've finished loading the new scene.
@rpc("any_peer", "call_remote", "reliable")
func notify_scene_loaded() -> void:
    if !isHost:
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    _log("Peer %d finished loading" % peerId)
    if is_peer_on_same_map(peerId):
        worldState.send_full_state(peerId)
        aiState.send_full_state(peerId)


## Injects [code]_cm[/code] into all patched nodes in the current scene.
## Called after every scene change so patches don't need [code]get_node_or_null[/code].
func inject_manager() -> void:
    var scene: Node = get_tree().current_scene
    if DEBUG:
        print("[coop] inject_manager: scene=%s" % (scene.scene_file_path if is_instance_valid(scene) else "<null>"))
    if !is_instance_valid(scene):
        return

    # Controller — known path
    var controller: Node = scene.get_node_or_null("Core/Controller")
    if controller != null && controller.has_method(&"init_manager"):
        controller.init_manager(self)

    # Interactor — single choke point for Door/Switch/Bed/Fire/LootContainer/Trader dispatch
    var interactor: Node = scene.get_node_or_null("Core/Controller/Camera/Interactor")
    if interactor == null:
        # Fallback — search by class
        for node: Node in scene.find_children("*", "RayCast3D", true, false):
            if node.get_script() != null && node.get_script().resource_path == "res://mod/patches/interactor_patch.gd":
                interactor = node
                break
    if interactor != null && interactor.has_method(&"init_manager"):
        interactor.init_manager(self)
        if DEBUG:
            print("[coop] inject_manager: Interactor patched at %s" % interactor.get_path())

    # Character — vitals/death handler
    var character: Node = scene.get_node_or_null("Core/Controller/Character")
    if character != null && character.has_method(&"init_manager"):
        character.init_manager(self)

    # Interface — inventory UI
    var iface: Node = scene.get_node_or_null("Core/UI/Interface")
    if iface != null && iface.has_method(&"init_manager"):
        iface.init_manager(self)

    # Settings — pause menu (settings_patch adds Multiplayer tab)
    var settings: Node = scene.get_node_or_null("Core/UI/Settings")
    if settings != null && settings.has_method(&"init_manager"):
        settings.init_manager(self)

    # Interactables: Doors, LootContainers
    for node: Node in get_tree().get_nodes_in_group(&"Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if obj.has_method(&"init_manager"):
            obj.init_manager(self)

    # Traders — trader_patch routes CompleteTask through the host.
    for node: Node in get_tree().get_nodes_in_group(&"Trader"):
        if node.has_method(&"init_manager"):
            node.init_manager(self)

    # Items: Pickups
    for node: Node in get_tree().get_nodes_in_group(&"Item"):
        if node.has_method(&"init_manager"):
            node.init_manager(self)

    # Transitions
    for node: Node in get_tree().get_nodes_in_group(&"Transition"):
        var obj: Node = node.owner if node.owner != null else node
        if obj.has_method(&"init_manager"):
            obj.init_manager(self)

    # AISpawner — at /root/Map/AI in game scenes
    var spawner: Node = scene.get_node_or_null("AI")
    if spawner != null && spawner.has_method(&"init_manager"):
        spawner.init_manager(self)

    # AI agents — inject into any already-active agents
    for node: Node in get_tree().get_nodes_in_group(&"AI"):
        if node.has_method(&"init_manager"):
            node.init_manager(self)

    # Main menu — apply co-op customization directly to the running instance
    # (patching Menu.gd doesn't work because ModLoader defers its init until
    # after Menu.tscn is already loaded with the original script).
    var scenePath: String = scene.scene_file_path if is_instance_valid(scene) else ""
    if scenePath == "res://Scenes/Menu.tscn":
        _customize_menu(scene)
        # Returning to menu from solo play — capture final state into the solo
        # dir. Skip if a coop session is active (disconnect_session handles that)
        # or if we just came back from coop (user:// may hold stale client saves
        # that would pollute the solo save).
        if !is_session_active() && !_wasInCoop:
            mirror_user_to_solo()
        _wasInCoop = false


## Modifies the running Menu instance in-place: renames New→Singleplayer,
## Load→Multiplayer, rebinds their signals, and creates submenu panels.
func _customize_menu(menu: Node) -> void:
    if menu.has_meta(&"coop_customized"):
        return
    menu.set_meta(&"coop_customized", true)

    var newButton: Button = menu.get_node_or_null("Main/Buttons/New")
    var loadButton: Button = menu.get_node_or_null("Main/Buttons/Load")
    if newButton == null || loadButton == null:
        _log("[menu] customize aborted: buttons missing")
        return

    newButton.text = "Singleplayer"
    loadButton.text = "Multiplayer"
    loadButton.disabled = false

    # Disconnect original signals
    var newSignalCallable: Callable = Callable(menu, "_on_new_pressed")
    var loadSignalCallable: Callable = Callable(menu, "_on_load_pressed")
    if newButton.pressed.is_connected(newSignalCallable):
        newButton.pressed.disconnect(newSignalCallable)
    if loadButton.pressed.is_connected(loadSignalCallable):
        loadButton.pressed.disconnect(loadSignalCallable)

    # Connect new handlers bound to the menu node
    newButton.pressed.connect(_on_singleplayer_pressed.bind(menu))
    loadButton.pressed.connect(_on_multiplayer_pressed.bind(menu))

    # Build the Multiplayer submenu once
    _build_mp_submenu(menu)
    _log("[menu] customized: Singleplayer/Multiplayer active")


func _on_singleplayer_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    # Should be impossible (button only exists on the main menu and a live
    # session means you're in-game), but guard anyway — wipe_user_saves()
    # would destroy the active session's state.
    if is_session_active():
        _log("[menu] Singleplayer pressed during active session — ignored")
        return
    # Restore the solo save into user:// so vanilla Continue/New Game flows see
    # the player's solo state. Wipe first to clear any leftover from a prior
    # coop session that didn't clean up properly.
    wipe_user_saves()
    mirror_solo_to_user()
    var main: Node = menu.get_node_or_null("Main")
    var modes: Node = menu.get_node_or_null("Modes")
    if main != null:
        main.hide()
    if modes != null:
        modes.show()


func _on_multiplayer_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var main: Node = menu.get_node_or_null("Main")
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    if main != null:
        main.hide()
    if submenu != null:
        submenu.show()


## Builds the Multiplayer submenu using the same full-screen single-VBox layout
## as the other coop dialogs (Host World / Browse Lobbies / New World) so all
## menus look stylistically consistent.
func _build_mp_submenu(menu: Node) -> void:
    if menu.get_node_or_null("CoopMPSubmenu") != null:
        return

    var gameTheme: Theme = load("res://UI/Themes/Theme.tres")

    var wrapper: Control = Control.new()
    wrapper.name = "CoopMPSubmenu"
    wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    wrapper.mouse_filter = Control.MOUSE_FILTER_STOP
    if gameTheme != null:
        wrapper.theme = gameTheme
    menu.add_child(wrapper)
    wrapper.hide()

    var outer: VBoxContainer = VBoxContainer.new()
    outer.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    outer.grow_horizontal = Control.GROW_DIRECTION_BOTH
    outer.grow_vertical = Control.GROW_DIRECTION_BOTH
    outer.custom_minimum_size = Vector2(560, 0)
    outer.add_theme_constant_override("separation", 4)
    wrapper.add_child(outer)

    var header: Label = Label.new()
    header.text = "Multiplayer"
    header.add_theme_font_size_override("font_size", 20)
    header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(header)

    var subheader: Label = Label.new()
    subheader.text = "Co-op mode"
    subheader.modulate = Color(1, 1, 1, 0.5)
    subheader.add_theme_font_size_override("font_size", 12)
    subheader.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(subheader)

    var topSpacer: Control = Control.new()
    topSpacer.custom_minimum_size = Vector2(0, 16)
    outer.add_child(topSpacer)

    var btnGrid: HBoxContainer = HBoxContainer.new()
    btnGrid.add_theme_constant_override("separation", 8)
    outer.add_child(btnGrid)

    # Left column: host buttons
    var hostCol: VBoxContainer = VBoxContainer.new()
    hostCol.add_theme_constant_override("separation", 4)
    hostCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btnGrid.add_child(hostCol)

    var hostBtn: Button = _mp_row_button("Host (Steam)")
    hostBtn.name = "HostBtn"
    hostBtn.disabled = true
    hostBtn.pressed.connect(_on_mp_host_pressed.bind(menu))
    hostCol.add_child(hostBtn)

    var hostIpBtn: Button = _mp_row_button("Host (IP)")
    hostIpBtn.pressed.connect(_on_mp_host_ip_pressed.bind(menu))
    hostCol.add_child(hostIpBtn)

    # Right column: join buttons
    var joinCol: VBoxContainer = VBoxContainer.new()
    joinCol.add_theme_constant_override("separation", 4)
    joinCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btnGrid.add_child(joinCol)

    var browseBtn: Button = _mp_row_button("Browse Lobbies")
    browseBtn.name = "BrowseBtn"
    browseBtn.disabled = true
    browseBtn.pressed.connect(_on_mp_browse_pressed.bind(menu))
    joinCol.add_child(browseBtn)

    var joinBtn: Button = _mp_row_button("Direct Join")
    joinBtn.pressed.connect(_on_mp_show_direct_join.bind(menu))
    joinCol.add_child(joinBtn)

    # Push footer to the bottom
    var footerSpacer: Control = Control.new()
    footerSpacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
    outer.add_child(footerSpacer)

    var logsBtn: Button = _mp_submenu_button("Open Logs Folder")
    logsBtn.pressed.connect(_on_mp_logs_pressed)
    outer.add_child(logsBtn)

    var returnBtn: Button = _mp_submenu_button("← Return")
    returnBtn.pressed.connect(_on_mp_back_pressed.bind(menu))
    outer.add_child(returnBtn)


func _mp_submenu_button(btnText: String) -> Button:
    var btn: Button = Button.new()
    btn.text = btnText
    btn.custom_minimum_size = Vector2(256, 40)
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    return btn


## Row button — expands to fill its share of the HBox equally.
func _mp_row_button(btnText: String) -> Button:
    var btn: Button = Button.new()
    btn.text = btnText
    btn.custom_minimum_size = Vector2(0, 40)
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return btn


func _on_mp_host_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    _pendingHostUseSteam = true
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    if submenu != null:
        submenu.hide()
    if is_instance_valid(coopUI):
        coopUI.show_lobby(true)


func _on_mp_host_ip_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    _pendingHostUseSteam = false
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    if submenu != null:
        submenu.hide()
    if is_instance_valid(coopUI):
        coopUI.show_lobby(false)


func _on_mp_show_direct_join(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    if submenu != null:
        submenu.hide()
    if is_instance_valid(coopUI):
        coopUI.show_direct_join_dialog()


func _on_mp_browse_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    if submenu != null:
        submenu.hide()
    if is_instance_valid(coopUI):
        coopUI.show_lobby_browser()


func _on_mp_logs_pressed() -> void:
    collect_logs()


func _on_mp_back_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null("CoopMPSubmenu")
    var main: Node = menu.get_node_or_null("Main")
    if submenu != null:
        submenu.hide()
    if main != null:
        main.show()


## Registers AI spawner pools with aiState for the current scene.
## Called deferred after scene load so the spawner's _ready() has completed.
func _register_ai_pools() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var spawner: Node = scene.get_node_or_null("AI")
    if spawner != null:
        aiState.register_spawner_pools(spawner)

# ---------- Rich Presence / Lobby Data ----------


## Updates Steam Rich Presence to show current co-op status on the friends list.
func _update_rich_presence() -> void:
    if !steamBridge.is_ready():
        return
    if !isActive:
        steamBridge.clear_rich_presence()
        return
    var playerCount: int = connectedPeers.size() + 1
    var mapName: String = _get_current_map_name()
    var status: String = "Co-op (%d players)" % playerCount
    if !mapName.is_empty():
        status = "%s — %s" % [mapName, status]
    steamBridge.set_rich_presence("steam_display", "#Status")
    steamBridge.set_rich_presence("status", status)


## Updates lobby metadata (map name, player count) visible in the lobby browser.
func _update_lobby_data() -> void:
    if !steamBridge.is_ready() || !isHost:
        return
    var playerCount: int = connectedPeers.size() + 1
    var mapName: String = _get_current_map_name()
    steamBridge.set_lobby_data("map", mapName)
    steamBridge.set_lobby_data("players", str(playerCount))
    var state: String = "menu" if _is_on_menu() else "in_game"
    steamBridge.set_lobby_data("state", state)


## Extracts a display-friendly map name from the current scene path.
func _get_current_map_name() -> String:
    if !is_instance_valid(get_tree().current_scene):
        return ""
    var path: String = get_tree().current_scene.scene_file_path
    if path.is_empty():
        return ""
    # "res://Scenes/Village.tscn" -> "Village"
    return path.get_file().get_basename()

# ---------- Per-World Save Mirroring ----------
# Vanilla Loader hard-codes user:// for save paths and we can't safely swap its
# script at runtime (breaks @onready references). Instead we mirror saves
# between user:// (Loader's working dir) and user://coop/<world_id>/ (persistent
# per-world storage). The world dir is loaded into user:// before play and
# user:// is written back into the world dir after every save event.

const COOP_WORLDS_DIR: String = "user://coop/"
const SOLO_SAVES_DIR: String = "user://solo/"
## File names that are world-level (shared by all players in the world).
const COOP_WORLD_SAVES: PackedStringArray = [
    "World.tres", "Cabin.tres", "Attic.tres", "Classroom.tres",
    "Tent.tres", "Bunker.tres", "Traders.tres",
]
## File name that is per-player and lives under players/<steam_id>/.
const COOP_PLAYER_SAVE: String = "Character.tres"
## Plain-text file at user:// root that holds the currently-active world ID.
## Persists across launches so a crash mid-session resumes the same world,
## and so save events know which world dir to mirror into.
const COOP_ACTIVE_WORLD_FILE: String = "user://coop_active.txt"


## Writes the active world ID to disk so subsequent save events (and the next
## launch in case of a crash) know which world dir to mirror into.
func set_active_world(activeWorldId: String) -> void:
    worldId = activeWorldId
    var f: FileAccess = FileAccess.open(COOP_ACTIVE_WORLD_FILE, FileAccess.WRITE)
    if f != null:
        f.store_string(activeWorldId)
        f.close()


## Returns the active world ID from disk (empty if no active world).
func get_active_world() -> String:
    if !FileAccess.file_exists(COOP_ACTIVE_WORLD_FILE):
        return ""
    var f: FileAccess = FileAccess.open(COOP_ACTIVE_WORLD_FILE, FileAccess.READ)
    if f == null:
        return ""
    var contents: String = f.get_as_text().strip_edges()
    f.close()
    return contents


## Clears the active world marker. Called on clean disconnect/return to menu.
func clear_active_world() -> void:
    worldId = ""
    if FileAccess.file_exists(COOP_ACTIVE_WORLD_FILE):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(COOP_ACTIVE_WORLD_FILE))


## Copies each user://*.tres into the world dir after a save event. The host
## calls this from transition_patch after super.Interact() commits saves.
## Fire-and-forget: I/O is dispatched to [WorkerThreadPool] so the transition
## scene load isn't stalled by 5-50MB of save-file copying. Directory creation
## stays on the main thread (fast, and avoids DirAccess races with the worker).
func mirror_user_to_world() -> void:
    if worldId.is_empty() || !isHost:
        return
    var worldDir: String = COOP_WORLDS_DIR + worldId + "/"
    DirAccess.make_dir_recursive_absolute(worldDir)
    var jobs: Array = []
    for saveName: String in COOP_WORLD_SAVES:
        var src: String = "user://" + saveName
        if FileAccess.file_exists(src):
            jobs.append([src, worldDir + saveName])
    # Per-player character lands in players/<steam_id>/Character.tres
    var steamId: String = steamBridge.localSteamID if steamBridge.is_ready() else "local"
    if FileAccess.file_exists("user://" + COOP_PLAYER_SAVE):
        var playerDir: String = worldDir + "players/" + steamId + "/"
        DirAccess.make_dir_recursive_absolute(playerDir)
        jobs.append(["user://" + COOP_PLAYER_SAVE, playerDir + COOP_PLAYER_SAVE])
    if !jobs.is_empty():
        WorkerThreadPool.add_task(_run_copy_jobs.bind(jobs), false, "coop:mirror_user_to_world")


## Copies the world dir into user:// before the host loads a world. Vanilla
## Loader then reads from user:// as if it were the regular save.
func mirror_world_to_user(forWorldId: String) -> void:
    var worldDir: String = COOP_WORLDS_DIR + forWorldId + "/"
    if !DirAccess.dir_exists_absolute(worldDir):
        return
    for saveName: String in COOP_WORLD_SAVES:
        var src: String = worldDir + saveName
        if FileAccess.file_exists(src):
            _copy_file(src, "user://" + saveName)
    var steamId: String = steamBridge.localSteamID if steamBridge.is_ready() else "local"
    var playerSrc: String = worldDir + "players/" + steamId + "/" + COOP_PLAYER_SAVE
    if FileAccess.file_exists(playerSrc):
        _copy_file(playerSrc, "user://" + COOP_PLAYER_SAVE)


## One-time migration on mod startup: if vanilla saves exist at user:// root and
## the solo dir doesn't exist yet, move them into user://solo/. Protects the
## player's pre-mod single-player progress from being wiped by coop sessions.
func migrate_solo_saves_if_needed() -> void:
    if DirAccess.dir_exists_absolute(SOLO_SAVES_DIR):
        return
    if !FileAccess.file_exists("user://World.tres"):
        return
    DirAccess.make_dir_recursive_absolute(SOLO_SAVES_DIR)
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    var migrated: int = 0
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            _copy_file("user://" + entry, SOLO_SAVES_DIR + entry)
            DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + entry))
            migrated += 1
        entry = dir.get_next()
    dir.list_dir_end()
    _log("Migrated %d solo save files to %s" % [migrated, SOLO_SAVES_DIR])


## Copies user://*.tres into the solo dir. Called from transition_patch when
## the player saves outside of a coop session, and from on_scene_changed when
## returning to the menu.
func mirror_user_to_solo() -> void:
    if !FileAccess.file_exists("user://World.tres"):
        return  # nothing to mirror
    DirAccess.make_dir_recursive_absolute(SOLO_SAVES_DIR)
    # Enumerate on main thread (quick), dispatch byte copies to worker pool.
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return
    var jobs: Array = []
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            jobs.append(["user://" + entry, SOLO_SAVES_DIR + entry])
        entry = dir.get_next()
    dir.list_dir_end()
    if !jobs.is_empty():
        WorkerThreadPool.add_task(_run_copy_jobs.bind(jobs), false, "coop:mirror_user_to_solo")


## Copies the solo dir into user:// so vanilla Loader picks them up. Called
## when the player clicks Singleplayer from the main menu.
func mirror_solo_to_user() -> void:
    if !DirAccess.dir_exists_absolute(SOLO_SAVES_DIR):
        return
    var dir: DirAccess = DirAccess.open(SOLO_SAVES_DIR)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres"):
            _copy_file(SOLO_SAVES_DIR + entry, "user://" + entry)
        entry = dir.get_next()
    dir.list_dir_end()


## Removes all .tres files from user:// (except Validator/Preferences) so a new
## world starts clean. Mirrors the wipe Loader.NewGame's FormatSave does.
func wipe_user_saves() -> void:
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            DirAccess.remove_absolute("user://" + entry)
        entry = dir.get_next()
    dir.list_dir_end()


func _copy_file(src: String, dst: String) -> void:
    var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
    # get_file_as_bytes returns empty on read failure — don't truncate dst
    # to zero bytes and silently corrupt the save.
    if bytes.is_empty():
        return
    var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
    if f != null:
        f.store_buffer(bytes)
        f.close()


## Batch copy helper executed by [WorkerThreadPool]. Each entry in [param jobs]
## is a [src, dst] pair. Runs on a worker thread — must not touch the scene
## tree or any Node state. FileAccess is safe across threads as long as each
## thread uses its own handle (one per job here).
static func _run_copy_jobs(jobs: Array) -> void:
    for pair: Array in jobs:
        var src: String = pair[0]
        var dst: String = pair[1]
        var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
        if bytes.is_empty():
            continue
        var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
        if f != null:
            f.store_buffer(bytes)
            f.close()


# ---------- Log Collection ----------


## Emitted once the async log snapshot finishes. [param absDir] is the absolute
## snapshot directory that was opened in the file manager.
signal logs_collected(absDir: String, fileCount: int)


## Collects godot.log and steam_helper.log into a timestamped folder under
## user://rtv-coop-logs/ and opens that folder in the system file manager.
## Cross-platform: user:// abstracts the path (Proton prefix on Linux, AppData
## on Windows), and OS.shell_open dispatches to the native file manager.
##
## Fire-and-forget: file I/O runs on [WorkerThreadPool] (snapshots can be tens
## of MB — used to freeze the UI for hundreds of ms on a button press). The
## directory enumeration runs on main thread (fast) so we can snapshot file
## names atomically before the worker starts. [signal logs_collected] fires
## once the snapshot is written and opened.
func collect_logs() -> void:
    var stamp: String = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
    var snapDir: String = "user://rtv-coop-logs/%s/" % stamp
    DirAccess.make_dir_recursive_absolute(snapDir)

    var sources: PackedStringArray = [
        "user://logs/godot.log",
        "user://logs/steam_helper.log",
    ]
    # Include recent session rollovers (godot writes godot<timestamp>.log for
    # restarts) — pick the last three by name (timestamp-sortable).
    var logsDir: DirAccess = DirAccess.open("user://logs/")
    if logsDir != null:
        var candidates: Array[String] = []
        logsDir.list_dir_begin()
        var entry: String = logsDir.get_next()
        while entry != "":
            if entry.ends_with(".log") && entry != "godot.log" && entry != "steam_helper.log":
                candidates.append(entry)
            entry = logsDir.get_next()
        logsDir.list_dir_end()
        candidates.sort()
        for i: int in range(max(0, candidates.size() - 3), candidates.size()):
            sources.append("user://logs/" + candidates[i])

    var info: Dictionary = {
        "stamp": stamp,
        "os": OS.get_name(),
        "godot": Engine.get_version_info().string,
    }
    WorkerThreadPool.add_task(
        _run_log_snapshot.bind(snapDir, sources, info), false, "coop:collect_logs"
    )


## Worker-thread body for [method collect_logs]. Writes every source file plus
## an info.txt into [param snapDir], then defers a callback to the main thread
## so [method OS.shell_open] fires from the scene tree (safe dispatch).
func _run_log_snapshot(snapDir: String, sources: PackedStringArray, info: Dictionary) -> void:
    var copied: int = 0
    for src: String in sources:
        if !FileAccess.file_exists(src):
            continue
        var dst: String = snapDir + src.get_file()
        var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
        if bytes.is_empty():
            continue
        var outFile: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
        if outFile != null:
            outFile.store_buffer(bytes)
            outFile.close()
            copied += 1
    var infoFile: FileAccess = FileAccess.open(snapDir + "info.txt", FileAccess.WRITE)
    if infoFile != null:
        infoFile.store_line("RTV Co-op Mod log snapshot")
        infoFile.store_line("Timestamp: %s" % info.get(&"stamp", ""))
        infoFile.store_line("OS: %s" % info.get(&"os", ""))
        infoFile.store_line("Godot: %s" % info.get(&"godot", ""))
        infoFile.store_line("Files: %d" % copied)
        infoFile.close()
    _on_log_snapshot_done.call_deferred(snapDir, copied)


## Main-thread callback for log snapshot completion — opens the folder in the
## native file manager and emits [signal logs_collected].
func _on_log_snapshot_done(snapDir: String, copied: int) -> void:
    var absDir: String = ProjectSettings.globalize_path(snapDir)
    _log("[logs] snapshot: %s (%d files)" % [absDir, copied])
    OS.shell_open(absDir)
    logs_collected.emit(absDir, copied)


# ---------- Auto-Join ----------


## Returns true if the current scene is the main menu (or no scene loaded).
func _is_on_menu() -> bool:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return true
    var path: String = scene.scene_file_path
    return path.is_empty() || path == "res://Scenes/Menu.tscn"


## Programmatically starts the game for a client joining via invite.
## Loads the last shelter if a save exists, otherwise creates a new game.
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


## Re-reads lobby state after ENet connects, in case host transitioned
## from menu to in-game during P2P tunnel setup.
func _recheck_host_state() -> void:
    if !steamBridge.is_ready():
        return
    if currentLobbyID.is_empty():
        return
    _recheckPending = true
    steamBridge.get_lobby_data(currentLobbyID, "state", _on_recheck_state)
    # Fallback — if callback never fires, clear the pending flag.
    get_tree().create_timer(_RECHECK_TIMEOUT_SEC).timeout.connect(_on_recheck_timeout)


func _on_recheck_state(response: Dictionary) -> void:
    _recheckPending = false
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", {})
    var hostState: String = data.get(&"value", "")
    if hostState == "in_game" && _is_on_menu():
        _log("Recheck: host is in-game — auto-loading")
        _client_start_load()


func _on_recheck_timeout() -> void:
    if !_recheckPending:
        return
    _recheckPending = false
    _log("Recheck timed out — staying on menu")


## Host tells all clients that the game is starting (menu → in-game transition).
@rpc("authority", "call_remote", "reliable")
func sync_game_start(sceneName: String) -> void:
    _log("Host started game (%s) — auto-loading" % sceneName)
    _client_start_load()


# ---------- World Save Management ----------


## Sets up save paths for the co-op world. Host only.
## Uses [member worldId] which is set by the world picker UI before hosting.
func _setup_save_paths() -> void:
    if worldId.is_empty():
        worldId = "world_%d" % Time.get_unix_time_from_system()
    var localSteamId: String = steamBridge.localSteamID if steamBridge.is_ready() else "local"
    _apply_save_paths("user://coop/%s/" % worldId, "user://coop/%s/players/%s/" % [worldId, localSteamId])


## Writes savePath/playerSavePath to Loader and ensures dirs exist.
## Uses the patched [code]savePath[/code] var when available, falls back to
## node metadata so callers still work if the loader_patch isn't applied.
func _apply_save_paths(sp: String, pp: String) -> void:
    if !is_instance_valid(loader):
        return
    if "savePath" in loader:
        loader.savePath = sp
        loader.playerSavePath = pp
    else:
        loader.set_meta(&"savePath", sp)
        loader.set_meta(&"playerSavePath", pp)
    DirAccess.make_dir_recursive_absolute(sp)
    DirAccess.make_dir_recursive_absolute(pp)
    _log("Save paths: world=%s player=%s" % [sp, pp])


func _get_save_path() -> String:
    if !is_instance_valid(loader):
        return "user://"
    if "savePath" in loader:
        return loader.savePath
    return loader.get_meta(&"savePath", "user://")


func _get_player_save_path() -> String:
    if !is_instance_valid(loader):
        return "user://"
    if "playerSavePath" in loader:
        return loader.playerSavePath
    return loader.get_meta(&"playerSavePath", "user://")


## Returns the active player's appearance from disk, or defaults if missing or
## the save path isn't set yet. Never returns null — callers can render safely.
func load_local_appearance() -> Dictionary:
    var dir: String = _get_player_save_path()
    var entry: Variant = AppearanceScript.load_from(dir)
    if entry == null:
        return AppearanceScript.get_defaults()
    return entry


## Returns true if an [code]appearance.json[/code] already exists for this
## player in the current co-op world. Used to decide whether to prompt the
## character-creation UI on session start.
func has_local_appearance() -> bool:
    var dir: String = _get_player_save_path()
    return FileAccess.file_exists(AppearanceScript.file_path(dir))


## Persists [param entry] to the current player save dir. Returns true on success.
## Rejects invalid paths (non-AI prefix, traversal) via [AppearanceScript.is_valid].
func save_local_appearance(entry: Dictionary) -> bool:
    var dir: String = _get_player_save_path()
    return AppearanceScript.save_to(dir, entry)


## Returns true if [param component] is safe for use in a file path (no traversal).
func _sanitize_path_component(component: String) -> bool:
    if component.is_empty():
        return false
    if component.find("..") != -1 || component.find("/") != -1 || component.find("\\") != -1:
        return false
    return true


## Resets save paths to default (solo mode).
func _reset_save_paths() -> void:
    worldId = ""
    _apply_save_paths("user://", "user://")


## Client requests the world ID from the host.
@rpc("any_peer", "call_remote", "reliable")
func _request_world_id() -> void:
    if !isHost:
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    # Include difficulty/season so client can match if they need a fresh save.
    var diff: int = 1
    var season: int = 1
    var worldPath: String = _get_save_path() + "World.tres"
    if FileAccess.file_exists(worldPath):
        var world: Resource = load(worldPath)
        if world != null:
            diff = world.get(&"difficulty") if world.get(&"difficulty") != null else 1
            season = world.get(&"season") if world.get(&"season") != null else 1
    _receive_world_id.rpc_id(peerId, worldId, diff, season)


## Client receives the world ID and sets up save paths, then triggers auto-load.
@rpc("authority", "call_remote", "reliable")
func _receive_world_id(hostWorldId: String, hostDifficulty: int, hostSeason: int) -> void:
    if !_sanitize_path_component(hostWorldId):
        _log("Invalid worldId from host: %s" % hostWorldId)
        return
    worldId = hostWorldId
    var localSteamId: String = steamBridge.localSteamID if steamBridge.is_ready() else str(localPeerId)
    _apply_save_paths("user://coop/%s/" % worldId, "user://coop/%s/players/%s/" % [worldId, localSteamId])
    # Store host's difficulty/season so _auto_load_game uses them if fresh save needed.
    set_meta(&"new_world_difficulty", hostDifficulty)
    set_meta(&"new_world_season", hostSeason)
    _log("Client new_world meta: diff=%d season=%d" % [hostDifficulty, hostSeason])
    # Now safe to auto-load since save paths are configured
    if pendingAutoJoin:
        pendingAutoJoin = false
        _client_start_load.call_deferred()
    elif _is_on_menu():
        # Direct connect has no Steam lobby — skip recheck and load immediately
        if currentLobbyID.is_empty():
            _client_start_load.call_deferred()
        else:
            _recheck_host_state()


## Client entry point that gates scene load behind the character-creation picker.
## If no appearance sidecar exists yet the picker is shown first; on confirm the
## scene loads, on cancel the client disconnects from the host. Without coopUI
## (headless / debug boot) we fall back to defaults + auto-load.
func _client_start_load() -> void:
    if has_local_appearance():
        _auto_load_game()
        return
    if is_instance_valid(coopUI):
        coopUI.show_character_picker(_on_client_picker_confirm, _on_client_picker_cancel)
    else:
        save_local_appearance(AppearanceScript.get_defaults())
        _auto_load_game()


func _on_client_picker_confirm(_entry: Dictionary = {}) -> void:
    if !has_local_appearance():
        save_local_appearance(AppearanceScript.get_defaults())
    _auto_load_game()


## Client Back button = give up on the join; tearing down the peer puts us
## back on the menu rather than leaving a half-connected session behind.
func _on_client_picker_cancel() -> void:
    _log("Client cancelled character picker — disconnecting")
    disconnect_session()


## Client sends their character save file to the host for storage.
## Called after SaveCharacter() completes.
func send_character_to_host() -> void:
    if isHost:
        return
    if !is_instance_valid(loader):
        return
    var charPath: String = _get_player_save_path() + "Character.tres"
    if !FileAccess.file_exists(charPath):
        return
    var fileData: PackedByteArray = FileAccess.get_file_as_bytes(charPath)
    if fileData.is_empty():
        return
    var localSteamId: String = steamBridge.localSteamID if steamBridge.is_ready() else str(localPeerId)
    _receive_client_character.rpc_id(1, localSteamId, fileData)
    _log("Sent character to host (%d bytes)" % fileData.size())


## Host receives a client's character save file and writes it to the world directory.
## Steam ID is looked up from [member peerSteamIDs] — not trusted from RPC args.
@rpc("any_peer", "call_remote", "reliable")
func _receive_client_character(clientSteamId: String, fileData: PackedByteArray) -> void:
    if !isHost:
        return
    var senderId: int = multiplayer.get_remote_sender_id()
    var trustedSteamId: String = peerSteamIDs.get(senderId, "")
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


## Host sends a stored character file to a requesting client.
## Called when a client joins and needs their character for this world.
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


## Client receives their character file from the host and writes it locally.
@rpc("authority", "call_remote", "reliable")
func _receive_host_character(fileData: PackedByteArray) -> void:
    if !is_instance_valid(loader):
        return
    if fileData.is_empty():
        _log("No stored character on host — starting fresh")
        return
    var dir: String = _get_player_save_path()
    if !DirAccess.dir_exists_absolute(dir):
        DirAccess.make_dir_recursive_absolute(dir)
    var filePath: String = dir + "Character.tres"
    var file: FileAccess = FileAccess.open(filePath, FileAccess.WRITE)
    if file != null:
        file.store_buffer(fileData)
        file.close()
        _log("Received character from host (%d bytes)" % fileData.size())

# ---------- Map Tracking ----------


## Returns the scene file path of the current map.
func get_current_map() -> String:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return ""
    return scene.scene_file_path


## Returns true if [param peerId] is on the same map as the local player.
func is_peer_on_same_map(peerId: int) -> bool:
    var localMap: String = get_current_map()
    if localMap.is_empty():
        return false
    return peerMaps.get(peerId, "") == localMap


## RPC: peer broadcasts which map they are on.
@rpc("any_peer", "call_remote", "reliable")
func sync_peer_map(mapPath: String) -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    var oldMap: String = peerMaps.get(senderId, "")
    peerMaps[senderId] = mapPath
    var localMap: String = get_current_map()
    _log("Peer %d map: %s" % [senderId, mapPath])

    if mapPath == localMap:
        # Peer arrived on our map — spawn their remote player
        spawn_remote_player.call_deferred(senderId)
        if isHost:
            worldState.send_full_state.call_deferred(senderId)
            aiState.send_full_state.call_deferred(senderId)
            _teardown_headless_map(mapPath)
    elif oldMap == localMap:
        # Peer left our map — despawn their remote player
        if senderId in remoteNodes:
            var node: Node3D = remoteNodes[senderId]
            if is_instance_valid(node):
                node.queue_free()
            remoteNodes.erase(senderId)
        playerState.clear_peer(senderId)

    # Host: manage headless maps for peers on maps the host isn't on
    if isHost:
        _update_headless_maps(senderId, oldMap, mapPath)

# ---------- Headless Map Management ----------


## Creates or updates headless maps when a peer changes maps.
func _update_headless_maps(peerId: int, oldMap: String, newMap: String) -> void:
    var localMap: String = get_current_map()

    # Remove peer from old headless map
    if !oldMap.is_empty() && oldMap != localMap && oldMap in headlessMaps:
        var oldHmap: Node = headlessMaps[oldMap]
        oldHmap.remove_client(peerId)
        if oldHmap.clientPeers.is_empty():
            mapSnapshots[oldMap] = oldHmap.snapshot()
            oldHmap.teardown()
            oldHmap.queue_free()
            headlessMaps.erase(oldMap)
            _log("Headless map freed: %s (snapshot saved)" % oldMap)

    # Add peer to new headless map (if host isn't on that map).
    # setup() kicks off a threaded scene load — restore + start are deferred
    # to the setup_finished handler so the main thread isn't blocked parsing
    # a 20-40MB PackedScene. Subsequent peers joining the same map before the
    # load completes just add to clientPeers; they'll see AI state once the
    # scene finalizes.
    if !newMap.is_empty() && newMap != localMap:
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


## Called once the threaded scene load finishes for a headless map. Applies any
## pending snapshot restore and starts the SubViewport.
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


## Tears down a headless map and returns its snapshot for handoff.
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


## Applies state from a headless SubViewport to the real scene after host arrives.
func _apply_handoff_state(snap: Dictionary) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var doors: Dictionary = snap.get(&"doors", {})
    for doorPath: String in doors:
        var door: Node = scene.get_node_or_null(doorPath)
        if !is_instance_valid(door) || !(door is Door):
            continue
        var state: Dictionary = doors[doorPath]
        door.isOpen = state.get(&"isOpen", false)
        door.locked = state.get(&"locked", false)
        if door.isOpen:
            door.animationTime = 4.0
    var switches: Dictionary = snap.get(&"switches", {})
    for switchPath: String in switches:
        var sw: Node = scene.get_node_or_null(switchPath)
        if !is_instance_valid(sw) || !sw.has_method(&"Activate"):
            continue
        var active: bool = switches[switchPath]
        if active && !sw.active:
            sw.Activate()
        elif !active && sw.active:
            sw.Deactivate()
    # Spawn items from headless snapshot (LootSimulation was skipped, so the
    # scene has no items yet — we transfer the ones generated in the SubViewport).
    var items: Array = snap.get(&"items", [])
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
        # Freeze at snapshot position so physics doesn't pull items off the
        # ground or jitter them (matches shelter-load pattern in Loader.gd).
        if pickup.has_method(&"Freeze"):
            pickup.Freeze()
        if pickup.has_method(&"UpdateAttachments"):
            pickup.UpdateAttachments()
        spawnedCount += 1
    _log("Handoff applied: %d doors, %d switches, %d items" % [doors.size(), switches.size(), spawnedCount])


## Forwards a client's position to the appropriate headless map.
func forward_position_to_headless(peerId: int, pos: Vector3, camPos: Vector3, rot: Vector3, flags: int) -> void:
    var peerMap: String = peerMaps.get(peerId, "")
    if peerMap.is_empty() || peerMap not in headlessMaps:
        return
    headlessMaps[peerMap].update_client_position(peerId, pos, camPos, rot, flags)

# ---------- Utility ----------


## Toggles mouse capture with backtick for debugging (editor only).
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


## Sets ENet timeout to survive scene loads over P2P tunnel.
## Scene transitions can block the main thread for 10+ seconds.
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


## Reads a session-wide setting. Returns [param fallback] when missing so
## patches can be written defensively without seeding every key up front.
func get_setting(key: String, fallback: Variant = null) -> Variant:
    return settings.get(key, fallback)


## Host-only: updates a session-wide setting and broadcasts the new value.
## Clients call this and it falls through to an RPC request to host.
func set_setting(key: String, value: Variant) -> void:
    if !isHost:
        if worldState != null && worldState.has_method(&"request_setting_change"):
            worldState.request_setting_change.rpc_id(1, key, value)
        return
    settings[key] = value
    if worldState != null && worldState.has_method(&"broadcast_settings"):
        worldState.broadcast_settings.rpc(settings)


## Dispatched by interactor_patch for each Interactable target.
## Returns true if the target was handled (caller skips local Interact).
## Returns false if caller should fall through to target.Interact().
func dispatch_interact(target: Node) -> bool:
    if !is_instance_valid(target) || !is_session_active():
        return false

    var scriptPath: String = target.get_script().resource_path if target.get_script() != null else ""

    # Bed — host runs locally + broadcasts sleep event so all peers freeze +
    # play transition audio for the same duration. Simulation time advance
    # rides on the existing sync_simulation broadcast.
    if scriptPath == "res://Scripts/Bed.gd":
        var scene: Node = get_tree().current_scene
        if !is_instance_valid(scene):
            return false
        if isHost:
            worldState.host_bed_interact(target)
        else:
            worldState.request_bed_interact.rpc_id(1, scene.get_path_to(target))
        return true

    # Remaining branches need scene-relative path — fetch once.
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return false

    # Door — host runs locally + broadcasts state; client requests host.
    if target is Door:
        if isHost:
            worldState.host_door_interact(target)
        else:
            worldState.request_door_interact.rpc_id(1, scene.get_path_to(target))
        return true

    # LootContainer — host opens UI locally + broadcasts loot; client requests host open.
    if target is LootContainer:
        if isHost:
            worldState.host_container_interact(target)
        else:
            worldState.request_container_open.rpc_id(1, scene.get_path_to(target))
        return true

    # Trader — host opens locally; client requests supply from host.
    if target is Trader:
        if isHost:
            worldState.host_trader_interact(target)
        else:
            worldState.request_trader_open.rpc_id(1, scene.get_path_to(target))
        return true

    # Switch — detected by script path (no class_name on Switch.gd).
    if scriptPath == "res://Scripts/Switch.gd":
        if isHost:
            worldState.host_switch_interact(target)
        else:
            worldState.request_switch_interact.rpc_id(1, scene.get_path_to(target))
        return true

    # Fire — detected by script path (no class_name on Fire.gd).
    if scriptPath == "res://Scripts/Fire.gd":
        if isHost:
            worldState.host_fire_interact(target)
        else:
            worldState.request_fire_interact.rpc_id(1, scene.get_path_to(target))
        return true

    # Unhandled type — caller should fall through to target.Interact().
    return false


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


## Walks up from a collider to find the remote player root node (CoopRemote group + peer_id meta).
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
