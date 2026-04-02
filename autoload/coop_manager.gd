## Main mod autoload for the Road to Vostok co-op mod.
## Manages ENet peer lifecycle, script patching, remote player spawning,
## and scene change detection. Persists across scene transitions.
extends Node

## Default ENet server port.
const DEFAULT_PORT: int = 9050
## Maximum number of clients that can connect to the host.
const MAX_CLIENTS: int = 3
## Enable debug logging to console.
const DEBUG: bool = true
## Force windowed mode on startup for multi-instance testing.
const DEV_WINDOWED: bool = true

## The local peer's multiplayer ID. 0 when not connected.
var localPeerId: int = 0
## Whether this instance is the host (server).
var isHost: bool = false
## Whether a multiplayer session is active (host or client).
var isActive: bool = false
## Connected remote peers. Maps peer_id -> [code]Node3D[/code] (RemotePlayer) or null.
var peers: Dictionary = { }
## Reference to the [code]PlayerState[/code] child node handling position sync.
var playerState: Node = null
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

	Log("Initialized")


func _physics_process(delta: float) -> void:
	sceneCheckTimer += delta
	if sceneCheckTimer < SCENE_CHECK_INTERVAL:
		return
	sceneCheckTimer = 0.0

	if get_tree().current_scene == null:
		return
	var currentPath: String = get_tree().current_scene.scene_file_path
	if currentPath != lastScenePath:
		lastScenePath = currentPath
		call_deferred("OnSceneChanged")


## Applies [code]take_over_path[/code] patches to game scripts.
func RegisterPatches() -> void:
	PatchScript("res://mod/patches/controller_patch.gd", "res://Scripts/Controller.gd")
	Log("Patches registered")


func PatchScript(patchPath: String, targetPath: String) -> void:
	var patch: Script = load(patchPath)
	patch.reload()
	patch.take_over_path(targetPath)

# ---------- Peer Lifecycle ----------


## Creates an ENet server on the given [param port].
func HostGame(port: int = DEFAULT_PORT) -> void:
	if IsConnected():
		Log("Already connected, disconnect first")
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
	Log("Hosting on port %d (id: %d)" % [port, localPeerId])


## Connects to a host at [param address]:[param port] as a client.
func JoinGame(address: String, port: int = DEFAULT_PORT) -> void:
	if IsConnected():
		Log("Already connected, disconnect first")
		return
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var error: Error = peer.create_client(address, port)
	if error != OK:
		Log("Failed to connect: %s" % error)
		return
	multiplayer.multiplayer_peer = peer
	isHost = false
	# isActive set in OnConnectedToServer after handshake completes
	Log("Connecting to %s:%d" % [address, port])


## Tears down the multiplayer session and cleans up all remote players.
func Disconnect() -> void:
	if !IsConnected():
		return
	for peerId: int in peers:
		var node: Node3D = peers[peerId]
		if is_instance_valid(node):
			node.free()
		playerState.ClearPeer(peerId)
	peers.clear()
	multiplayer.multiplayer_peer = null
	localPeerId = 0
	isHost = false
	isActive = false
	Log("Disconnected")

# ---------- Signal Handlers ----------


func OnPeerConnected(peerId: int) -> void:
	Log("Peer connected: %d" % peerId)
	peers[peerId] = null
	SpawnRemotePlayer(peerId)


func OnPeerDisconnected(peerId: int) -> void:
	Log("Peer disconnected: %d" % peerId)
	RemoveRemotePlayer(peerId)
	playerState.ClearPeer(peerId)
	peers.erase(peerId)


func OnConnectedToServer() -> void:
	localPeerId = multiplayer.get_unique_id()
	isActive = true
	Log("Connected to server (id: %d)" % localPeerId)


func OnConnectionFailed() -> void:
	Log("Connection failed")
	multiplayer.multiplayer_peer = null
	isActive = false


func OnServerDisconnected() -> void:
	Log("Server disconnected")
	Disconnect()

# ---------- Remote Player Management ----------


## Instantiates a [code]RemotePlayer[/code] ghost for [param peerId] under the current map.
## Only spawns if a gameplay scene with [code]Core/Controller[/code] is loaded.
func SpawnRemotePlayer(peerId: int) -> void:
	var mapNode: Node = get_tree().current_scene
	if mapNode == null:
		return
	if mapNode.get_node_or_null("Core/Controller") == null:
		return

	playerState.ClearPeer(peerId)

	var remote: Node3D = remotePlayerScene.instantiate()
	remote.name = "RemotePlayer_%d" % peerId
	remote.set_meta("peer_id", peerId)
	mapNode.add_child(remote)
	peers[peerId] = remote
	Log("Spawned remote player for peer %d" % peerId)


## Frees the [code]RemotePlayer[/code] node for [param peerId] and nulls the reference.
func RemoveRemotePlayer(peerId: int) -> void:
	if peerId not in peers:
		return
	var node: Node3D = peers[peerId]
	if is_instance_valid(node):
		node.free()
	peers[peerId] = null


## Returns the [code]RemotePlayer[/code] node for [param peerId], or null if invalid/missing.
func GetRemotePlayerNode(peerId: int) -> Node3D:
	var node: Node3D = peers.get(peerId)
	return node if is_instance_valid(node) else null

# ---------- Scene Change Handling ----------


func OnSceneChanged() -> void:
	if !IsConnected():
		return
	for peerId: int in peers:
		RemoveRemotePlayer(peerId)
		SpawnRemotePlayer(peerId)
	Log("Scene changed, remote players respawned")

# ---------- Utility ----------


## Toggles mouse capture with Tab or backtick for debugging.
func _input(event: InputEvent) -> void:
	if !(event is InputEventKey) || !event.pressed || event.echo:
		return
	match event.keycode:
		KEY_TAB, KEY_QUOTELEFT:
			var current: Input.MouseMode = Input.get_mouse_mode()
			if current == Input.MOUSE_MODE_CAPTURED || current == Input.MOUSE_MODE_CONFINED_HIDDEN:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## Writes windowed display preferences so the game starts windowed for testing.
func ForceWindowed() -> void:
	var prefs: Preferences = Preferences.Load() as Preferences
	if !prefs:
		prefs = Preferences.new()
	prefs.displayMode = 2
	prefs.windowSize = 3
	prefs.Save()


## Returns [code]true[/code] if a real multiplayer peer is active (not [code]OfflineMultiplayerPeer[/code]).
func IsConnected() -> bool:
	return !(multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


func Log(msg: String) -> void:
	if DEBUG:
		print("[CoopManager] %s" % msg)
