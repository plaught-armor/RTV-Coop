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
## Maps multiplayer peer ID -> display name (Steam persona or fallback).
var peerNames: Dictionary[int, String] = { }
## Maps multiplayer peer ID -> Steam ID string.
var peerSteamIDs: Dictionary[int, String] = { }
## Cached avatar textures keyed by Steam ID string.
var avatarCache: Dictionary[String, ImageTexture] = { }
## Reference to the [code]PlayerState[/code] child node handling position sync.
var playerState: Node = null
## Reference to the [code]WorldState[/code] child node handling world sync.
var worldState: Node = null
## Reference to the [code]SteamBridge[/code] child node for Steam helper IPC.
var steamBridge: Node = null
## Reference to the co-op UI panel.
var coopUI: Control = null

## Consolidated preloads — children access these via [code]_cm.PropertyName[/code].
var remotePlayerScene: PackedScene = preload("res://mod/presentation/remote_player.tscn")
var PlayerStateScript: Script = preload("res://mod/network/player_state.gd")
var SlotSerializerScript: Script = preload("res://mod/network/slot_serializer.gd")
var audioLibrary: AudioLibrary = preload("res://Resources/AudioLibrary.tres")
var gd: GameData = preload("res://Resources/GameData.tres")
var lastScenePath: String = ""
## Check scene every 60 physics frames (~0.5s at 120Hz).
const SCENE_CHECK_FRAMES: int = 60


func _ready() -> void:
    if DEBUG:
        force_windowed()

    register_patches()

    playerState = load("res://mod/network/player_state.gd").new()
    playerState.name = "PlayerState"
    add_child(playerState)
    playerState.init_manager(self)

    worldState = load("res://mod/network/world_state.gd").new()
    worldState.name = "WorldState"
    add_child(worldState)
    worldState.init_manager(self)

    steamBridge = load("res://mod/network/steam_bridge.gd").new()
    steamBridge.name = "SteamBridge"
    add_child(steamBridge)
    steamBridge.init_manager(self)

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

    inject_manager.call_deferred()
    # Defer Steam helper launch until after ModLoader finishes
    steamBridge.launch.call_deferred()
    _log("Initialized (debug: %s)" % str(DEBUG))


func _physics_process(_delta: float) -> void:
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


## Applies [code]take_over_path[/code] patches to game scripts.
func register_patches() -> void:
    var patches: Array[Array] = [
        ["res://mod/patches/controller_patch.gd", "res://Scripts/Controller.gd"],
        ["res://mod/patches/door_patch.gd", "res://Scripts/Door.gd"],
        ["res://mod/patches/switch_patch.gd", "res://Scripts/Switch.gd"],
        ["res://mod/patches/transition_patch.gd", "res://Scripts/Transition.gd"],
        ["res://mod/patches/pickup_patch.gd", "res://Scripts/Pickup.gd"],
        ["res://mod/patches/interface_patch.gd", "res://Scripts/Interface.gd"],
    ]
    for pair: Array in patches:
        var patch: Script = load(pair[0])
        patch.reload()
        patch.take_over_path(pair[1])
    _log("Patches registered (%d)" % patches.size())

# ---------- Peer Lifecycle ----------


## Creates an ENet server and a Steam P2P listen socket + lobby.
func host_game(port: int = DEFAULT_PORT) -> void:
    if is_session_active():
        _log("Already connected, disconnect first")
        return
    if !DEBUG && !steamBridge.ownsGame:
        _log("Cannot host — game ownership not verified")
        return
    var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
    var error: Error = peer.create_server(port, MAX_CLIENTS)
    if error != OK:
        _log("Failed to create server: %s" % error)
        return
    multiplayer.multiplayer_peer = peer
    localPeerId = multiplayer.get_unique_id()
    isHost = true
    isActive = true
    peerNames[localPeerId] = steamBridge.localSteamName if steamBridge.is_ready() else "Host"

    if steamBridge.is_ready():
        steamBridge.start_p2p_host(on_p2p_host_ready, port)
        steamBridge.create_lobby(MAX_CLIENTS + 1, on_lobby_created)

    worldState.start_item_tracking()
    _log("Hosting on port %d (id: %d)" % [port, localPeerId])


## Connects to a host at [param address]:[param port] as a client.
## Called internally by [method on_p2p_tunnel_ready] with the tunnel's localhost port,
## or directly in DEBUG mode for ENet direct-connect.
func join_game(address: String, port: int = DEFAULT_PORT) -> void:
    if is_session_active():
        _log("Already connected, disconnect first")
        return
    if !steamBridge.ownsGame && !DEBUG:
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
    multiplayer.multiplayer_peer = null
    localPeerId = 0
    isHost = false
    isActive = false
    worldState.stop_item_tracking()
    steamBridge.leave_lobby()
    _log("Disconnected")

# ---------- Signal Handlers ----------


func on_peer_connected(peerId: int) -> void:
    _log("Peer connected: %d" % peerId)
    connectedPeers.append(peerId)
    spawn_remote_player.call_deferred(peerId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc_id(peerId, get_local_name(), localSteamID)
    # Set generous timeout on the new peer connection
    set_peer_timeout(peerId)
    # Send current world state to the new peer
    if isHost:
        worldState.send_full_state.call_deferred(peerId)


func on_peer_disconnected(peerId: int) -> void:
    _log("Peer disconnected: %d" % peerId)
    var idx: int = connectedPeers.find(peerId)
    if idx >= 0:
        connectedPeers.remove_at(idx)
    playerState.clear_peer(peerId)
    peerNames.erase(peerId)
    peerSteamIDs.erase(peerId)
    if peerId in remoteNodes:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
        remoteNodes.erase(peerId)


func on_connected_to_server() -> void:
    localPeerId = multiplayer.get_unique_id()
    isActive = true
    peerNames[localPeerId] = get_local_name()
    set_peer_timeout(1) # Server is always peer ID 1
    worldState.start_item_tracking()
    _log("Connected to server (id: %d)" % localPeerId)
    var localSteamID: String = steamBridge.localSteamID if steamBridge.is_ready() else ""
    sync_name.rpc(get_local_name(), localSteamID)


func on_connection_failed() -> void:
    _log("Connection failed")
    multiplayer.multiplayer_peer = null
    isActive = false


func on_server_disconnected() -> void:
    _log("Server disconnected")
    disconnect_session()

# ---------- Steam Callbacks ----------


func on_lobby_created(response: Dictionary) -> void:
    if !response.get("ok", false):
        _log("Lobby creation failed: %s" % response.get("error", "unknown"))
        return
    var lobbyID: String = response.get("data", { }).get("lobby_id", "")
    _log("Steam lobby created: %s" % lobbyID)


func on_p2p_host_ready(response: Dictionary) -> void:
    if !response.get("ok", false):
        _log("P2P host failed: %s" % response.get("error", "unknown"))
        return
    _log("P2P host listening for Steam peers")


func on_p2p_tunnel_ready(response: Dictionary) -> void:
    if !response.get("ok", false):
        _log("P2P tunnel failed: %s" % response.get("error", "unknown"))
        return
    var tunnelPort: int = response.get("data", { }).get("tunnel_port", 0)
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
    # Update name label on existing remote player node
    if senderId in remoteNodes:
        var remote: Node3D = remoteNodes[senderId]
        if is_instance_valid(remote):
            remote.get_node("NameLabel").text = sanitized
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
func fetch_avatar(steamID: String) -> void:
    if steamID.is_empty() || steamID in avatarCache:
        return
    if !steamBridge.is_ready():
        return
    steamBridge.send_command("get_avatar", { "steam_id": steamID }, on_avatar_received)


func on_avatar_received(response: Dictionary) -> void:
    if !response.get("ok", false):
        return
    var data: Dictionary = response.get("data", { })
    var steamID: String = data.get("steam_id", "")
    var avatarB64: String = data.get("avatar", "")
    if steamID.is_empty() || avatarB64.is_empty():
        return
    var w: int = data.get("avatar_w", 32)
    var h: int = data.get("avatar_h", 32)
    var raw: PackedByteArray = Marshalls.base64_to_raw(avatarB64)
    var img: Image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, raw)
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
    var mapNode: Node = get_tree().current_scene
    if !is_instance_valid(mapNode):
        return
    if mapNode.get_node_or_null("Core/Controller") == null:
        return

    playerState.clear_peer(peerId)

    var remote: Node3D = remotePlayerScene.instantiate()
    remote.name = "RemotePlayer_%d" % peerId
    remote.set_meta("peer_id", peerId)
    remote.tree_exiting.connect(on_remote_node_exiting.bind(peerId))
    mapNode.add_child(remote)
    remote.init_manager(self)
    # Set display name from peer registry
    var displayName: String = get_peer_name(peerId)
    remote.get_node("NameLabel").text = displayName
    remoteNodes[peerId] = remote
    _log("Spawned remote player for peer %d (%s)" % [peerId, displayName])


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
    inject_manager()
    if !is_session_active():
        return
    ensure_all_spawned()
    # Reset item tracking for the new scene
    if worldState.trackingItems:
        worldState.syncedItems.clear()
        worldState.consumedSyncIDs.clear()
        worldState.droppedItemHistory.clear()
        worldState.syncIdCounter = 0
    if isHost:
        pass
    else:
        notify_scene_loaded.rpc_id(1)
    _log("Scene changed, remote players respawned")


## Client tells host they've finished loading the new scene.
@rpc("any_peer", "call_remote", "reliable")
func notify_scene_loaded() -> void:
    if !isHost:
        return
    var peerId: int = multiplayer.get_remote_sender_id()
    _log("Peer %d finished loading" % peerId)
    worldState.send_full_state(peerId)


## Injects [code]_cm[/code] into all patched nodes in the current scene.
## Called after every scene change so patches don't need [code]get_node_or_null[/code].
func inject_manager() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return

    # Controller — known path
    var controller: Node = scene.get_node_or_null("Core/Controller")
    if controller != null && controller.has_method("init_manager"):
        controller.init_manager(self)

    # Interface — inventory UI
    var iface: Node = scene.get_node_or_null("Core/UI/Interface")
    if iface != null && iface.has_method("init_manager"):
        iface.init_manager(self)

    # Interactables: Doors, LootContainers
    for node: Node in get_tree().get_nodes_in_group("Interactable"):
        var obj: Node = node.owner if node.owner != null else node
        if obj.has_method("init_manager"):
            obj.init_manager(self)

    # Items: Pickups
    for node: Node in get_tree().get_nodes_in_group("Item"):
        if node.has_method("init_manager"):
            node.init_manager(self)

    # Switches
    for node: Node in get_tree().get_nodes_in_group("Switch"):
        var obj: Node = node.owner if node.owner != null else node
        if obj.has_method("init_manager"):
            obj.init_manager(self)

    # Transitions
    for node: Node in get_tree().get_nodes_in_group("Transition"):
        var obj: Node = node.owner if node.owner != null else node
        if obj.has_method("init_manager"):
            obj.init_manager(self)

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


func get_local_ip() -> String:
    for addr: String in IP.get_local_addresses():
        if addr.begins_with("127.") || addr.begins_with("::") || ":" in addr:
            continue
        return addr
    return "127.0.0.1"


func _log(msg: String) -> void:
    print("[CoopManager] %s" % msg)
