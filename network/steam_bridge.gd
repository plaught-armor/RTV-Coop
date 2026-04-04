## Manages the Steam helper binary lifecycle and TCP communication.
## Launches the Go helper process, connects via localhost TCP, and provides
## an async command API for Steam operations (user info, ownership, lobbies).
extends Node

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager



## TCP port the helper listens on. Fixed at 27099 for Proton (wrapper launches helper).
## Randomized per instance in editor for multi-instance testing.
var HELPER_PORT: int = 27099
## Max time to wait for helper TCP to be ready after launch.
const CONNECT_TIMEOUT: float = 15.0
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
    var libSrc: String = get_steam_lib_res_path()

    var helperDst: String = get_helper_user_path()
    var libDst: String = get_steam_lib_user_path()
    extract_file(helperSrc, helperDst)
    extract_file(libSrc, libDst)
    extract_file("res://mod/bin/steam_appid.txt", "user://steam_appid.txt")

    if OS.get_name() == "Linux":
        OS.execute("chmod", ["+x", ProjectSettings.globalize_path(helperDst)])

    _log("Helper dir: %s" % ProjectSettings.globalize_path("user://"))
    _log("SteamAppId env: %s" % OS.get_environment("SteamAppId"))

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
        if !connecting:
            _log("Connect loop ended (connected: %s)" % str(connected))
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
    ownsGame = true  # Assume ownership — launched through Steam
    _log("Steam user: %s (%s)" % [localSteamName, localSteamID])
    # Cache our own avatar
    if !localSteamID.is_empty():
        _cm.fetch_avatar(localSteamID)
    # Check if launched via Steam invite
    check_launch_invite(on_launch_invite_checked)


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


## Returns true if the helper is connected and user info is cached.
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


func get_friends(callback: Callable) -> void:
    send_command("get_friends", { }, callback)


func invite_friend(steamID: String, callback: Callable) -> void:
    send_command("invite_friend", { "steam_id": steamID }, callback)


func open_invite_dialog(callback: Callable) -> void:
    send_command("open_invite_dialog", { }, callback)


func check_launch_invite(callback: Callable) -> void:
    send_command("check_launch_invite", { }, callback)


func on_launch_invite_checked(response: Dictionary) -> void:
    if !response.get("ok", false):
        return
    var data: Dictionary = response.get("data", { })
    var lobbyID: String = data.get("lobby_id", "")
    if lobbyID.is_empty():
        return
    _log("Launch invite detected — joining lobby %s" % lobbyID)
    _cm.coopUI.on_lobby_join_pressed(lobbyID)


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
    var data: PackedByteArray = read_from_res(resPath)
    if data.is_empty():
        data = read_from_vmz(resPath)
    if data.is_empty():
        _log("Cannot read: %s" % resPath)
        return
    var dst: FileAccess = FileAccess.open(userPath, FileAccess.WRITE)
    if dst == null:
        _log("Cannot write: %s" % userPath)
        return
    dst.store_buffer(data)
    dst.close()
    _log("Extracted: %s -> %s (%d bytes)" % [resPath, userPath, data.size()])


## Reads a file from res:// (works for editor and PCK-embedded files).
func read_from_res(resPath: String) -> PackedByteArray:
    var src: FileAccess = FileAccess.open(resPath, FileAccess.READ)
    if src == null:
        return PackedByteArray()
    var data: PackedByteArray = src.get_buffer(src.get_length())
    src.close()
    return data


## Reads a file from the .vmz archive directly (fallback when res:// can't access binaries).
func read_from_vmz(resPath: String) -> PackedByteArray:
    var modsDir: String = OS.get_executable_path().get_base_dir().path_join("mods")
    var vmzPath: String = modsDir.path_join("rtv-coop.vmz")
    if !FileAccess.file_exists(vmzPath):
        _log("VMZ not found at: %s" % vmzPath)
        return PackedByteArray()
    var zip: ZIPReader = ZIPReader.new()
    if zip.open(vmzPath) != OK:
        _log("Cannot open VMZ: %s" % vmzPath)
        return PackedByteArray()
    # res://mod/bin/file -> mod/bin/file inside the archive
    var archivePath: String = resPath.replace("res://", "")
    if !zip.file_exists(archivePath):
        _log("Not in VMZ: %s" % archivePath)
        zip.close()
        return PackedByteArray()
    var data: PackedByteArray = zip.read_file(archivePath)
    zip.close()
    return data

# ---------- Platform Paths ----------


## Detects if running under Proton/Wine.
func is_proton() -> bool:
    return OS.get_name() == "Windows" && OS.has_environment("STEAM_COMPAT_DATA_PATH")


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
    print("[SteamBridge] %s" % msg)
