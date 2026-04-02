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
## Enable debug logging and ENet direct-connect fallback.
const DEBUG: bool = true
## Force windowed mode on startup for multi-instance testing.
const DEV_WINDOWED: bool = true
## Known MD5 hashes of patched scripts that this mod was built against.
const CONTROLLER_HASH: String = "da2049367c3298a152dc0cb35217ad9a"
const DOOR_HASH: String = "2f7397b8801d17304a102661df6fd327"
const SWITCH_HASH: String = "89fbf23ff77c2a35b45ab6678607fb98"
const TRANSITION_HASH: String = "c370261a9529c4bd74d19faf5b7ad2f8"
const PICKUP_HASH: String = "bc1af42d61966dab4a02eabeb8d3ab10"
const LOOT_CONTAINER_HASH: String = "988851b309f6db683dcbf5e95a7c0666"

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
## Reference to the [code]PlayerState[/code] child node handling position sync.
var playerState: PlayerState = null
## Reference to the [code]WorldState[/code] child node handling world sync.
var worldState: WorldState = null
## Reference to the [code]SteamBridge[/code] child node for Steam helper IPC.
var steamBridge: SteamBridge = null
## Reference to the co-op UI panel.
var coopUI: Control = null

var remotePlayerScene: PackedScene = preload("res://mod/presentation/remote_player.tscn")
var lastScenePath: String = ""
var sceneCheckTimer: float = 0.0
const SCENE_CHECK_INTERVAL: float = 0.5


func _ready() -> void:
    if DEV_WINDOWED:
        ForceWindowed()

    RegisterPatches()

    playerState = load("res://mod/network/player_state.gd").new()
    playerState.name = "PlayerState"
    add_child(playerState)

    worldState = load("res://mod/network/world_state.gd").new()
    worldState.name = "WorldState"
    add_child(worldState)

    steamBridge = load("res://mod/network/steam_bridge.gd").new()
    steamBridge.name = "SteamBridge"
    add_child(steamBridge)

    var uiLayer: CanvasLayer = CanvasLayer.new()
    uiLayer.name = "CoopUILayer"
    uiLayer.layer = 100
    add_child(uiLayer)
    coopUI = load("res://mod/ui/coop_ui.gd").new()
    coopUI.name = "CoopUI"
    uiLayer.add_child(coopUI)

    var coopHUD: VBoxContainer = load("res://mod/ui/coop_hud.gd").new()
    coopHUD.name = "CoopHUD"
    uiLayer.add_child(coopHUD)

    multiplayer.peer_connected.connect(OnPeerConnected)
    multiplayer.peer_disconnected.connect(OnPeerDisconnected)
    multiplayer.connected_to_server.connect(OnConnectedToServer)
    multiplayer.connection_failed.connect(OnConnectionFailed)
    multiplayer.server_disconnected.connect(OnServerDisconnected)

    # Always launch Steam helper
    steamBridge.Launch()

    Log("Initialized (debug: %s)" % str(DEBUG))


func _physics_process(delta: float) -> void:
    sceneCheckTimer += delta
    if sceneCheckTimer < SCENE_CHECK_INTERVAL:
        return
    sceneCheckTimer = 0.0

    if !is_instance_valid(get_tree().current_scene):
        return
    var currentPath: String = get_tree().current_scene.scene_file_path
    if currentPath != lastScenePath:
        lastScenePath = currentPath
        call_deferred("OnSceneChanged")
    elif isActive:
        EnsureAllSpawned()


## Applies [code]take_over_path[/code] patches to game scripts.
## Checks file hashes before patching and warns if the game has been updated.
func RegisterPatches() -> void:
    for pair: Array in [
        ["res://Scripts/Controller.gd", CONTROLLER_HASH, "res://mod/patches/controller_patch.gd"],
        ["res://Scripts/Door.gd", DOOR_HASH, "res://mod/patches/door_patch.gd"],
        ["res://Scripts/Switch.gd", SWITCH_HASH, "res://mod/patches/switch_patch.gd"],
        ["res://Scripts/Transition.gd", TRANSITION_HASH, "res://mod/patches/transition_patch.gd"],
        ["res://Scripts/Pickup.gd", PICKUP_HASH, "res://mod/patches/pickup_patch.gd"],
        # LootContainer patch disabled — conflicts with TraderDisplay.gd type checks
        # ["res://Scripts/LootContainer.gd", LOOT_CONTAINER_HASH, "res://mod/patches/loot_container_patch.gd"],
    ]:
        if !VerifyHash(pair[0], pair[1]):
            Log("WARNING: %s has changed — mod may be incompatible" % pair[0])
        PatchScript(pair[2], pair[0])
    Log("Patches registered")


func PatchScript(patchPath: String, targetPath: String) -> void:
    var patch: Script = load(patchPath)
    patch.reload()
    patch.take_over_path(targetPath)


func VerifyHash(path: String, expectedHash: String) -> bool:
    var fileHash: String = FileAccess.get_md5(path)
    return fileHash == expectedHash

# ---------- Peer Lifecycle ----------


## Creates an ENet server and a Steam P2P listen socket + lobby.
func HostGame(port: int = DEFAULT_PORT) -> void:
    if IsConnected():
        Log("Already connected, disconnect first")
        return
    if !DEBUG && !steamBridge.ownsGame:
        Log("Cannot host — game ownership not verified")
        return
    var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
    var error: Error = peer.create_server(port, MAX_CLIENTS)
    if error != OK:
        Log("Failed to create server: %s" % error)
        return
    multiplayer.multiplayer_peer = peer
    localPeerId = multiplayer.get_unique_id()
    isHost = true
    isActive = true
    peerNames[localPeerId] = steamBridge.localSteamName if steamBridge.IsReady() else "Host"

    if steamBridge.IsReady():
        steamBridge.StartP2PHost(OnP2PHostReady, port)
        steamBridge.CreateLobby(MAX_CLIENTS + 1, OnLobbyCreated)

    Log("Hosting on port %d (id: %d)" % [port, localPeerId])


## Connects to a host at [param address]:[param port] as a client.
## Called internally by [method OnP2PTunnelReady] with the tunnel's localhost port,
## or directly in DEBUG mode for ENet direct-connect.
func JoinGame(address: String, port: int = DEFAULT_PORT) -> void:
    if IsConnected():
        Log("Already connected, disconnect first")
        return
    if !steamBridge.ownsGame && !DEBUG:
        Log("Cannot join — game ownership not verified")
        return
    var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
    var error: Error = peer.create_client(address, port)
    if error != OK:
        Log("Failed to connect: %s" % error)
        return
    multiplayer.multiplayer_peer = peer
    isHost = false
    Log("Connecting to %s:%d" % [address, port])


## Tears down the multiplayer session and cleans up all remote players.
func Disconnect() -> void:
    if !IsConnected():
        return
    for peerId: int in connectedPeers:
        playerState.ClearPeer(peerId)
    for peerId: int in remoteNodes:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
    remoteNodes.clear()
    connectedPeers.clear()
    peerNames.clear()
    multiplayer.multiplayer_peer = null
    localPeerId = 0
    isHost = false
    isActive = false
    steamBridge.LeaveLobby()
    Log("Disconnected")

# ---------- Signal Handlers ----------


func OnPeerConnected(peerId: int) -> void:
    Log("Peer connected: %d" % peerId)
    connectedPeers.append(peerId)
    SpawnRemotePlayer.call_deferred(peerId)
    SyncName.rpc_id(peerId, GetLocalName())
    # Set generous timeout on the new peer connection
    SetPeerTimeout(peerId)
    # Send current world state to the new peer
    if isHost:
        worldState.SendFullState.call_deferred(peerId)


func OnPeerDisconnected(peerId: int) -> void:
    Log("Peer disconnected: %d" % peerId)
    var idx: int = connectedPeers.find(peerId)
    if idx >= 0:
        connectedPeers.remove_at(idx)
    playerState.ClearPeer(peerId)
    peerNames.erase(peerId)
    if peerId in remoteNodes:
        var node: Node3D = remoteNodes[peerId]
        if is_instance_valid(node):
            node.queue_free()
        remoteNodes.erase(peerId)


func OnConnectedToServer() -> void:
    localPeerId = multiplayer.get_unique_id()
    isActive = true
    peerNames[localPeerId] = GetLocalName()
    SetPeerTimeout(1) # Server is always peer ID 1
    Log("Connected to server (id: %d)" % localPeerId)
    SyncName.rpc(GetLocalName())


func OnConnectionFailed() -> void:
    Log("Connection failed")
    multiplayer.multiplayer_peer = null
    isActive = false


func OnServerDisconnected() -> void:
    Log("Server disconnected")
    Disconnect()

# ---------- Steam Callbacks ----------


func OnLobbyCreated(response: Dictionary) -> void:
    if !response.get("ok", false):
        Log("Lobby creation failed: %s" % response.get("error", "unknown"))
        return
    var lobbyID: String = response.get("data", { }).get("lobby_id", "")
    Log("Steam lobby created: %s" % lobbyID)


func OnP2PHostReady(response: Dictionary) -> void:
    if !response.get("ok", false):
        Log("P2P host failed: %s" % response.get("error", "unknown"))
        return
    Log("P2P host listening for Steam peers")


func OnP2PTunnelReady(response: Dictionary) -> void:
    if !response.get("ok", false):
        Log("P2P tunnel failed: %s" % response.get("error", "unknown"))
        return
    var tunnelPort: int = response.get("data", { }).get("tunnel_port", 0)
    if tunnelPort == 0:
        Log("P2P tunnel returned invalid port")
        return
    Log("P2P tunnel ready on 127.0.0.1:%d — connecting ENet" % tunnelPort)
    JoinGame("127.0.0.1", tunnelPort)

# ---------- Name Sync ----------


## Returns the local player's display name.
func GetLocalName() -> String:
    if steamBridge.IsReady():
        return steamBridge.localSteamName
    return "Player_%d" % localPeerId


## Returns the display name for [param peerId], or a fallback.
func GetPeerName(peerId: int) -> String:
    return peerNames.get(peerId, "Player_%d" % peerId)


## RPC: receives a peer's display name. Clamped to 64 chars, control chars stripped.
@rpc("any_peer", "call_remote", "reliable")
func SyncName(peerName: String) -> void:
    var senderId: int = multiplayer.get_remote_sender_id()
    var sanitized: String = SanitizeName(peerName)
    peerNames[senderId] = sanitized
    Log("Peer %d name: %s" % [senderId, sanitized])


func SanitizeName(rawName: String) -> String:
    var truncated: String = rawName.substr(0, 64)
    var clean: String = ""
    for i: int in truncated.length():
        var c: String = truncated[i]
        if c.unicode_at(0) >= 32:
            clean += c
    return clean if !clean.is_empty() else "Unknown"

# ---------- Remote Player Management ----------


func SpawnRemotePlayer(peerId: int) -> void:
    if peerId in remoteNodes:
        return
    var mapNode: Node = get_tree().current_scene
    if !is_instance_valid(mapNode):
        return
    if mapNode.get_node_or_null("Core/Controller") == null:
        return

    playerState.ClearPeer(peerId)

    var remote: Node3D = remotePlayerScene.instantiate()
    remote.name = "RemotePlayer_%d" % peerId
    remote.set_meta("peer_id", peerId)
    remote.tree_exiting.connect(OnRemoteNodeExiting.bind(peerId))
    mapNode.add_child(remote)
    remoteNodes[peerId] = remote
    Log("Spawned remote player for peer %d" % peerId)


func OnRemoteNodeExiting(peerId: int) -> void:
    remoteNodes.erase(peerId)


func GetRemotePlayerNode(peerId: int) -> Node3D:
    return remoteNodes.get(peerId)


func EnsureAllSpawned() -> void:
    for peerId: int in connectedPeers:
        if peerId not in remoteNodes:
            SpawnRemotePlayer(peerId)

# ---------- Scene Change Handling ----------


func OnSceneChanged() -> void:
    if !IsConnected():
        return
    EnsureAllSpawned()
    Log("Scene changed, remote players respawned")

# ---------- Utility ----------


## Toggles mouse capture with backtick for debugging.
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


func ForceWindowed() -> void:
    var prefs: Preferences = Preferences.Load() as Preferences
    if prefs == null:
        prefs = Preferences.new()
    prefs.displayMode = 2
    prefs.windowSize = 3
    prefs.Save()


## Disables ENet timeout on a peer. Connection only drops on actual network failure.
func SetPeerTimeout(peerId: int) -> void:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if !(peer is ENetMultiplayerPeer):
        return
    var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer
    var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
    if enetPeer != null:
        enetPeer.set_timeout(0, 0, 0)


func IsConnected() -> bool:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if peer == null || peer is OfflineMultiplayerPeer:
        return false
    return peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func GetLocalIP() -> String:
    for addr: String in IP.get_local_addresses():
        if addr.begins_with("127.") || addr.begins_with("::") || ":" in addr:
            continue
        return addr
    return "127.0.0.1"


func Log(msg: String) -> void:
    if DEBUG:
        print("[CoopManager] %s" % msg)
