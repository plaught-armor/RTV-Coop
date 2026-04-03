## Manages the Steam helper binary lifecycle and TCP communication.
## Launches the Go helper process, connects via localhost TCP, and provides
## an async command API for Steam operations (user info, ownership, lobbies).
extends Node

## TCP port the helper listens on. Randomized per instance to allow multiple.
var HELPER_PORT: int = 27099 + (OS.get_process_id() % 100)
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
func launch() -> void:
    if helperPID >= 0:
        return

    var helperSrc: String = get_helper_res_path()
    var helperDst: String = get_helper_user_path()
    var libSrc: String = get_steam_lib_res_path()
    var libDst: String = get_steam_lib_user_path()

    # Extract helper binary + Steam SDK lib + appid to user://
    extract_file(helperSrc, helperDst)
    extract_file(libSrc, libDst)
    extract_file("res://mod/bin/steam_appid.txt", "user://steam_appid.txt")

    # Make executable on Linux
    if OS.get_name() == "Linux":
        OS.execute("chmod", ["+x", ProjectSettings.globalize_path(helperDst)])

    # Launch helper process
    var globalPath: String = ProjectSettings.globalize_path(helperDst)
    var args: PackedStringArray = ["--port", str(HELPER_PORT)]
    helperPID = OS.create_process(globalPath, args)
    if helperPID < 0:
        _log("Failed to launch Steam helper")
        return

    _log("Steam helper launched (PID: %d)" % helperPID)
    connecting = true
    connectTimer = 0.0


func _process(delta: float) -> void:
    if connecting:
        poll_connect(delta)
        return

    if !connected:
        return

    tcp.poll()
    if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        connected = false
        _log("Steam helper TCP disconnected")
        return

    read_responses()


## Attempts TCP connection to the helper with retries.
func poll_connect(delta: float) -> void:
    connectTimer += delta

    if connectTimer >= CONNECT_TIMEOUT:
        connecting = false
        _log("Steam helper connect timeout")
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
            _log("Steam helper TCP connected")
            # Immediately fetch user info
            get_user(on_initial_user)
        StreamPeerTCP.STATUS_ERROR:
            # Retry
            tcp = StreamPeerTCP.new()


func on_initial_user(response: Dictionary) -> void:
    var data: Dictionary = response.get("data", { })
    localSteamName = data.get("name", "")
    localSteamID = data.get("steam_id", "")
    _log("Steam user: %s (%s)" % [localSteamName, localSteamID])
    # Chain ownership check now that we know who we are
    check_ownership(on_ownership_result)


func on_ownership_result(response: Dictionary) -> void:
    var data: Dictionary = response.get("data", { })
    ownsGame = data.get("owns", false)
    if ownsGame:
        _log("Ownership verified")
    else:
        _log("Ownership check FAILED — co-op disabled")


## Reads complete JSON lines from TCP and dispatches to pending callbacks.
func read_responses() -> void:
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
func send_command(cmd: String, params: Dictionary, callback: Callable) -> void:
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
func shutdown() -> void:
    if connected:
        tcp.disconnect_from_host()
        connected = false
    if helperPID >= 0:
        OS.kill(helperPID)
        helperPID = -1
    pendingCallbacks.clear()
    _log("Steam helper shut down")


func _exit_tree() -> void:
    shutdown()


## Returns true if the helper is running, connected, and user info is cached.
func is_ready() -> bool:
    return connected && !localSteamID.is_empty()

# ---------- Command API ----------


func get_user(callback: Callable) -> void:
    send_command("get_user", { }, callback)


func check_ownership(callback: Callable) -> void:
    send_command("check_ownership", { }, callback)


func create_lobby(maxPlayers: int, callback: Callable) -> void:
    send_command("create_lobby", { "max_players": maxPlayers }, callback)


func list_lobbies(callback: Callable) -> void:
    send_command("list_lobbies", { }, callback)


func join_lobby(lobbyID: String, callback: Callable) -> void:
    send_command("join_lobby", { "lobby_id": lobbyID }, callback)


func leave_lobby() -> void:
    if connected:
        send_command("leave_lobby", { }, Callable())


## Starts a Steam Networking Sockets P2P listen socket on the host.
## Incoming Steam peers are relayed to the local ENet server on [param enetPort].
func start_p2p_host(callback: Callable, enetPort: int = 9050) -> void:
    send_command("start_p2p_host", { "enet_port": enetPort }, callback)


## Connects to a host via Steam P2P and creates a local UDP tunnel.
## Returns the [code]tunnel_port[/code] that the game's ENet client should connect to.
func start_p2p_client(hostSteamID: String, callback: Callable) -> void:
    send_command("start_p2p_client", { "host_steam_id": hostSteamID }, callback)

# ---------- File Extraction ----------


func extract_file(resPath: String, userPath: String) -> void:
    if FileAccess.file_exists(userPath):
        return
    var src: FileAccess = FileAccess.open(resPath, FileAccess.READ)
    if src == null:
        _log("Cannot read: %s" % resPath)
        return
    var data: PackedByteArray = src.get_buffer(src.get_length())
    src.close()
    var dst: FileAccess = FileAccess.open(userPath, FileAccess.WRITE)
    if dst == null:
        _log("Cannot write: %s" % userPath)
        return
    dst.store_buffer(data)
    dst.close()

# ---------- Platform Paths ----------


func get_helper_res_path() -> String:
    match OS.get_name():
        "Windows":
            return "res://mod/bin/steam_helper.exe"
        _:
            return "res://mod/bin/steam_helper_linux"


func get_helper_user_path() -> String:
    match OS.get_name():
        "Windows":
            return "user://steam_helper.exe"
        _:
            return "user://steam_helper"


func get_steam_lib_res_path() -> String:
    match OS.get_name():
        "Windows":
            return "res://mod/bin/steam_api64.dll"
        _:
            return "res://mod/bin/libsteam_api.so"


func get_steam_lib_user_path() -> String:
    match OS.get_name():
        "Windows":
            return "user://steam_api64.dll"
        _:
            return "user://libsteam_api.so"


func _log(msg: String) -> void:
    if CoopManager.DEBUG:
        print("[SteamBridge] %s" % msg)
