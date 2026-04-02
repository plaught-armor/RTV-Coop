## Manages the Steam helper binary lifecycle and TCP communication.
## Launches the Go helper process, connects via localhost TCP, and provides
## an async command API for Steam operations (user info, ownership, lobbies).
class_name SteamBridge
extends Node

## TCP port the helper listens on.
const HELPER_PORT: int = 27099
## Max time to wait for helper TCP to be ready after launch.
const CONNECT_TIMEOUT: float = 5.0
## Poll interval for TCP connection attempts.
const CONNECT_RETRY: float = 0.25

var helperPID: int = -1
var tcp: StreamPeerTCP = StreamPeerTCP.new()
var connected: bool = false
var readBuffer: String = ""

## Cached Steam identity after first get_user call.
var localSteamName: String = ""
var localSteamID: String = ""
## Cached ownership result after first check_ownership call.
var ownsGame: bool = false

## Pending async callbacks keyed by command name.
var pendingCallbacks: Dictionary[String, Callable] = { }

var connectTimer: float = 0.0
var connecting: bool = false


## Extracts the helper binary to user://, launches it, and begins TCP connection.
func Launch() -> void:
	if helperPID >= 0:
		return

	var helperSrc: String = GetHelperResPath()
	var helperDst: String = GetHelperUserPath()
	var libSrc: String = GetSteamLibResPath()
	var libDst: String = GetSteamLibUserPath()

	# Extract helper binary from res:// to user://
	ExtractFile(helperSrc, helperDst)
	ExtractFile(libSrc, libDst)

	# Make executable on Linux
	if OS.get_name() == "Linux":
		OS.execute("chmod", ["+x", ProjectSettings.globalize_path(helperDst)])

	# Launch helper process
	var globalPath: String = ProjectSettings.globalize_path(helperDst)
	var args: PackedStringArray = ["--port", str(HELPER_PORT)]
	helperPID = OS.create_process(globalPath, args)
	if helperPID < 0:
		Log("Failed to launch Steam helper")
		return

	Log("Steam helper launched (PID: %d)" % helperPID)
	connecting = true
	connectTimer = 0.0


func _process(delta: float) -> void:
	if connecting:
		PollConnect(delta)
		return

	if !connected:
		return

	tcp.poll()
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		connected = false
		Log("Steam helper TCP disconnected")
		return

	ReadResponses()


## Attempts TCP connection to the helper with retries.
func PollConnect(delta: float) -> void:
	connectTimer += delta

	if connectTimer >= CONNECT_TIMEOUT:
		connecting = false
		Log("Steam helper connect timeout")
		return

	var status: StreamPeerTCP.Status = tcp.get_status()
	match status:
		StreamPeerTCP.STATUS_NONE:
			tcp.connect_to_host("127.0.0.1", HELPER_PORT)
		StreamPeerTCP.STATUS_CONNECTING:
			tcp.poll()
		StreamPeerTCP.STATUS_CONNECTED:
			connecting = false
			connected = true
			Log("Steam helper TCP connected")
			# Immediately fetch user info
			GetUser(OnInitialUser)
		StreamPeerTCP.STATUS_ERROR:
			# Retry
			tcp = StreamPeerTCP.new()


func OnInitialUser(response: Dictionary) -> void:
	var data: Dictionary = response.get("data", { })
	localSteamName = data.get("name", "")
	localSteamID = data.get("steam_id", "")
	Log("Steam user: %s (%s)" % [localSteamName, localSteamID])


## Reads complete JSON lines from TCP and dispatches to pending callbacks.
func ReadResponses() -> void:
	var available: int = tcp.get_available_bytes()
	if available <= 0:
		return

	var chunk: PackedByteArray = tcp.get_data(available)[1]
	readBuffer += chunk.get_string_from_utf8()

	while "\n" in readBuffer:
		var newlineIdx: int = readBuffer.find("\n")
		var line: String = readBuffer.substr(0, newlineIdx)
		readBuffer = readBuffer.substr(newlineIdx + 1)

		if line.is_empty():
			continue

		var response: Variant = JSON.parse_string(line)
		if response == null || !(response is Dictionary):
			continue

		var cmd: String = response.get("cmd", "")
		if cmd in pendingCallbacks:
			var cb: Callable = pendingCallbacks[cmd]
			pendingCallbacks.erase(cmd)
			if cb.is_valid():
				cb.call(response)


## Sends a JSON command to the helper and registers a callback for the response.
func SendCommand(cmd: String, params: Dictionary, callback: Callable) -> void:
	if !connected:
		if callback.is_valid():
			callback.call({ "ok": false, "cmd": cmd, "error": "not connected" })
		return

	var payload: Dictionary = { "cmd": cmd }
	if !params.is_empty():
		payload["params"] = params
	var jsonLine: String = "%s\n" % JSON.stringify(payload)
	tcp.put_data(jsonLine.to_utf8_buffer())
	pendingCallbacks[cmd] = callback


## Shuts down the helper process and TCP connection.
func Shutdown() -> void:
	if connected:
		tcp.disconnect_from_host()
		connected = false
	if helperPID >= 0:
		OS.kill(helperPID)
		helperPID = -1
	pendingCallbacks.clear()
	Log("Steam helper shut down")


func _exit_tree() -> void:
	Shutdown()


## Returns true if the helper is running, connected, and user info is cached.
func IsReady() -> bool:
	return connected && !localSteamID.is_empty()

# ---------- Command API ----------


func GetUser(callback: Callable) -> void:
	SendCommand("get_user", { }, callback)


func CheckOwnership(callback: Callable) -> void:
	SendCommand("check_ownership", { }, callback)


func CreateLobby(maxPlayers: int, callback: Callable, hostIP: String = "", hostPort: int = 9050) -> void:
	SendCommand("create_lobby", { "max_players": maxPlayers, "host_ip": hostIP, "host_port": hostPort }, callback)


func ListLobbies(callback: Callable) -> void:
	SendCommand("list_lobbies", { }, callback)


func JoinLobby(lobbyID: String, callback: Callable) -> void:
	SendCommand("join_lobby", { "lobby_id": lobbyID }, callback)


func LeaveLobby() -> void:
	if connected:
		SendCommand("leave_lobby", { }, Callable())

# ---------- File Extraction ----------


func ExtractFile(resPath: String, userPath: String) -> void:
	if FileAccess.file_exists(userPath):
		return
	var src: FileAccess = FileAccess.open(resPath, FileAccess.READ)
	if src == null:
		Log("Cannot read: %s" % resPath)
		return
	var data: PackedByteArray = src.get_buffer(src.get_length())
	src.close()
	var dst: FileAccess = FileAccess.open(userPath, FileAccess.WRITE)
	if dst == null:
		Log("Cannot write: %s" % userPath)
		return
	dst.store_buffer(data)
	dst.close()

# ---------- Platform Paths ----------


func GetHelperResPath() -> String:
	match OS.get_name():
		"Windows":
			return "res://mod/bin/steam_helper.exe"
		_:
			return "res://mod/bin/steam_helper_linux"


func GetHelperUserPath() -> String:
	match OS.get_name():
		"Windows":
			return "user://steam_helper.exe"
		_:
			return "user://steam_helper"


func GetSteamLibResPath() -> String:
	match OS.get_name():
		"Windows":
			return "res://mod/bin/steam_api64.dll"
		_:
			return "res://mod/bin/libsteam_api.so"


func GetSteamLibUserPath() -> String:
	match OS.get_name():
		"Windows":
			return "user://steam_api64.dll"
		_:
			return "user://libsteam_api.so"


func Log(msg: String) -> void:
	if CoopManager.DEBUG:
		print("[SteamBridge] %s" % msg)
