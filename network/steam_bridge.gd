## Manages the Steam helper binary lifecycle and TCP communication.
## Launches the Go helper process, connects via localhost TCP, and provides
## an async command API for Steam operations (user info, ownership, lobbies).
extends Node





## TCP port the helper listens on. Fixed at 27099 for Proton (wrapper launches helper).
## Randomized per instance in editor for multi-instance testing.
var HELPER_PORT: int = 27099
## Max time to wait for helper TCP to be ready after launch.
const CONNECT_TIMEOUT: float = 15.0
## Poll interval for TCP connection attempts.
const CONNECT_RETRY: float = 0.25

## Helper lifecycle states. Previously tracked with two bools (connecting /
## connected); combined into a single enum so illegal combinations
## (connecting && connected) are unrepresentable.
enum State { IDLE, CONNECTING, CONNECTED }
var state: State = State.IDLE

var helperPID: int = -1
var tcp: StreamPeerTCP = StreamPeerTCP.new()
var readBuffer: PackedByteArray = PackedByteArray()
## Read offset into readBuffer — avoids copying on every dispatch cycle.
## Buffer is compacted only when readOffset exceeds half the buffer size.
var readOffset: int = 0
const COMPACT_THRESHOLD: int = 4096
var newlineByte: int = "\n".to_utf8_buffer()[0]
## Binary message marker byte (0x00). JSON lines always start with '{' (0x7B).
const BIN_MARKER: int = 0x00
## Pending binary avatar callback keyed by steam_id.
var pendingAvatarCallbacks: Dictionary[String, Callable] = {}

## Cached Steam identity after first get_user call.
var localSteamName: String = ""
var localSteamID: String = ""
## Cached ownership result after first check_ownership call.
var ownsGame: bool = false

## Pending async callbacks keyed by request ID (int).
var pendingCallbacks: Dictionary[int, Callable] = {}

## Last successful get_friends response. Retained across scene changes so the
## in-game Settings Multiplayer tab can paint the list immediately from the
## main-menu lobby's earlier fetch instead of waiting for a fresh IPC round-trip.
var friendsCache: Array = []
var friendsCacheMs: int = 0
## Monotonic request ID counter.
var nextReqId: int = 1

var connectTimer: float = 0.0


func launch() -> void:
    if helperPID >= 0:
        return

    # Kill any stale helper from a prior RTV crash. _exit_tree doesn't fire on
    # force-close, leaving the helper process alive + port 27099 held; our new
    # spawn then can't bind and the TCP poll stalls for CONNECT_TIMEOUT.
    _kill_stale_helpers()

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
    # Helper self-locates its log. Passing --log-file with a space-containing
    # Wine path seemed to break launch on Proton — revert to self-locate.
    var args: PackedStringArray = ["--port", str(HELPER_PORT)]
    _log("launching: %s args=%s" % [globalPath, args])
    helperPID = OS.create_process(globalPath, args)

    if helperPID < 0:
        _log("Failed to launch Steam helper")
        return
    _log("Steam helper launched (PID: %d)" % helperPID)

    state = State.CONNECTING
    connectTimer = 0.0


func _process(delta: float) -> void:
    if state == State.CONNECTING:
        poll_connect(delta)
        if state != State.CONNECTING:
            _log("Connect loop ended (state: %s)" % State.keys()[state])
        return

    if state != State.CONNECTED:
        return

    tcp.poll()
    if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        state = State.IDLE
        _log("Steam helper TCP disconnected")
        return

    read_responses()


## Aborts an in-flight connect loop early. Called when the user commits to an
## IP-host session (no Steam path needed), so we stop polling the helper TCP
## and spamming retries for the full [code]CONNECT_TIMEOUT[/code] window.
func abort_connect() -> void:
    if state != State.CONNECTING:
        return
    state = State.IDLE
    connectTimer = 0.0
    if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        tcp.disconnect_from_host()
    _log("Steam helper connect aborted (IP host path)")


func poll_connect(delta: float) -> void:
    connectTimer += delta

    if connectTimer >= CONNECT_TIMEOUT:
        state = State.IDLE
        _log("Steam helper connect timeout")
        return

    var status: StreamPeerTCP.Status = tcp.get_status()
    match status:
        StreamPeerTCP.STATUS_NONE:
            tcp.connect_to_host("127.0.0.1", HELPER_PORT)
        StreamPeerTCP.STATUS_CONNECTING:
            tcp.poll()
        StreamPeerTCP.STATUS_CONNECTED:
            state = State.CONNECTED
            _log("Steam helper TCP connected")
            # Immediately fetch user info
            get_user(on_initial_user)
        StreamPeerTCP.STATUS_ERROR:
            # Retry
            tcp = StreamPeerTCP.new()


func on_initial_user(response: Dictionary) -> void:
    var data: Dictionary = response.get(&"data", { }) as Dictionary
    localSteamName = data.get(&"name", "")
    localSteamID = data.get(&"steam_id", "")
    ownsGame = true # Assume ownership — launched through Steam
    _log("Steam user: %s (%s)" % [localSteamName, localSteamID])
    # Cache our own avatar
    if !localSteamID.is_empty():
        CoopManager.fetch_avatar(localSteamID)
    # Check if launched via Steam invite
    check_launch_invite(on_launch_invite_checked)


func on_ownership_result(response: Dictionary) -> void:
    var data: Dictionary = response.get(&"data", { }) as Dictionary
    ownsGame = data.get(&"owns", false)
    if ownsGame:
        _log("Ownership verified")
    else:
        _log("Ownership check FAILED — co-op disabled")


## Reads complete JSON lines from TCP and dispatches to pending callbacks.
## Uses PackedByteArray with offset tracking to avoid copying on every cycle.
## Buffer is compacted only when consumed data exceeds [constant COMPACT_THRESHOLD].
func read_responses() -> void:
    var available: int = tcp.get_available_bytes()
    if available <= 0:
        return

    var chunk: PackedByteArray = tcp.get_data(available)[1]
    readBuffer.append_array(chunk)

    var bufSize: int = readBuffer.size()
    while readOffset < bufSize:
        # Binary message: [0x00][4 bytes length BE][payload]
        if readBuffer[readOffset] == BIN_MARKER:
            if bufSize - readOffset < 5:
                break
            var msgLen: int = (readBuffer[readOffset + 1] << 24) | (readBuffer[readOffset + 2] << 16) | (readBuffer[readOffset + 3] << 8) | readBuffer[readOffset + 4]
            if bufSize - readOffset < 5 + msgLen:
                break
            var payload: PackedByteArray = readBuffer.slice(readOffset + 5, readOffset + 5 + msgLen)
            _dispatch_binary(payload)
            readOffset += 5 + msgLen
            continue

        # JSON line: terminated by newline
        var nlIdx: int = readBuffer.find(newlineByte, readOffset)
        if nlIdx < 0:
            break
        if nlIdx > readOffset:
            var lineBytes: PackedByteArray = readBuffer.slice(readOffset, nlIdx)
            var line: String = lineBytes.get_string_from_utf8()
            _dispatch_response(line)
        readOffset = nlIdx + 1

    # Compact buffer when consumed data exceeds threshold
    if readOffset >= COMPACT_THRESHOLD:
        readBuffer = readBuffer.slice(readOffset)
        readOffset = 0


## Dispatches a binary message. Format: [1 byte type][type-specific payload].
## Type 0x01 = avatar: [1 byte steam_id_len][steam_id bytes][2 bytes w BE][2 bytes h BE][RGBA bytes]
func _dispatch_binary(payload: PackedByteArray) -> void:
    if payload.is_empty():
        return
    var msgType: int = payload[0]
    if msgType == 0x01:
        # Avatar binary
        if payload.size() < 6:
            return
        var idLen: int = payload[1]
        if payload.size() < 2 + idLen + 4:
            return
        var steamID: String = payload.slice(2, 2 + idLen).get_string_from_utf8()
        var w: int = (payload[2 + idLen] << 8) | payload[3 + idLen]
        var h: int = (payload[4 + idLen] << 8) | payload[5 + idLen]
        var rgbaStart: int = 6 + idLen
        var expectedSize: int = w * h * 4
        if payload.size() < rgbaStart + expectedSize:
            return
        var rgba: PackedByteArray = payload.slice(rgbaStart, rgbaStart + expectedSize)
        if steamID in pendingAvatarCallbacks:
            var cb: Callable = pendingAvatarCallbacks[steamID]
            pendingAvatarCallbacks.erase(steamID)
            if cb.is_valid():
                cb.call(steamID, w, h, rgba)


func _dispatch_response(line: String) -> void:
    var response: Variant = JSON.parse_string(line)
    if response == null || !(response is Dictionary):
        push_warning("[steam_bridge] Malformed response payload dropped: %s" % line.substr(0, 200))
        return

    var cmd: String = response.get(&"cmd", "")

    # Handle push events from the helper (no pending callback, no req_id)
    if cmd == "invite_received":
        on_invite_received(response)
        return

    # Match by req_id for normal command responses
    var reqId: int = response.get(&"req_id", 0)
    if reqId > 0 && reqId in pendingCallbacks:
        var cb: Callable = pendingCallbacks[reqId]
        pendingCallbacks.erase(reqId)
        if cb.is_valid():
            cb.call(response)


## Sends a JSON command to the helper and registers a callback for the response.
## Each command gets a unique [code]req_id[/code] so multiple calls of the same
func send_command(cmd: String, params: Dictionary, callback: Callable) -> void:
    if state != State.CONNECTED:
        if callback.is_valid():
            callback.call({ "ok": false, "cmd": cmd, "error": "not connected" })
        return

    var reqId: int = nextReqId
    nextReqId += 1
    var payload: Dictionary = { "cmd": cmd, "req_id": reqId }
    if !params.is_empty():
        payload["params"] = params
    var jsonLine: String = "%s\n" % JSON.stringify(payload)
    tcp.put_data(jsonLine.to_utf8_buffer())
    if callback.is_valid():
        pendingCallbacks[reqId] = callback


## Kills any leftover helper processes from a previous RTV run. Matches by
## executable name so the kill hits whichever platform's helper is lingering
## (native Linux binary or the Proton-wrapped Windows binary visible to
func _kill_stale_helpers() -> void:
    match OS.get_name():
        "Linux":
            OS.execute("pkill", ["-9", "-f", "steam_helper_linux"])
            OS.execute("pkill", ["-9", "-f", "steam_helper.exe"])
        "Windows":
            OS.execute("taskkill", ["/F", "/IM", "steam_helper.exe"])
        _:
            pass


func shutdown() -> void:
    if state == State.CONNECTED:
        tcp.disconnect_from_host()
        state = State.IDLE
    if helperPID >= 0:
        OS.kill(helperPID)
        helperPID = -1
    pendingCallbacks.clear()
    _log("Steam helper shut down")


func _exit_tree() -> void:
    shutdown()


func is_ready() -> bool:
    return state == State.CONNECTED && !localSteamID.is_empty()



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
    if state == State.CONNECTED:
        send_command("leave_lobby", { }, Callable())


func get_friends(callback: Callable) -> void:
    send_command("get_friends", { }, _cache_friends_response.bind(callback))


## Intercepts [method get_friends] responses, stores the latest list in
## [member friendsCache], then forwards to the original caller. Bound args
func _cache_friends_response(response: Dictionary, callback: Callable) -> void:
    if response.get(&"ok", false):
        var data: Variant = response.get(&"data", [])
        friendsCache = data as Array
        friendsCacheMs = Time.get_ticks_msec()
    if callback.is_valid():
        callback.call(response)


func invite_friend(steamID: String, callback: Callable) -> void:
    send_command("invite_friend", { "steam_id": steamID }, callback)


func open_invite_dialog(callback: Callable) -> void:
    send_command("open_invite_dialog", { }, callback)


func check_launch_invite(callback: Callable) -> void:
    send_command("check_launch_invite", { }, callback)


## Requests a binary avatar transfer. The helper sends raw RGBA bytes via the binary
## channel instead of base64 JSON. Callback signature: (steamID, w, h, rgba: PackedByteArray).
func get_avatar_binary(steamID: String, callback: Callable) -> void:
    if state != State.CONNECTED:
        return
    pendingAvatarCallbacks[steamID] = callback
    send_command("get_avatar_bin", { "steam_id": steamID }, Callable())


func on_invite_received(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", { }) as Dictionary
    var lobbyID: String = data.get(&"lobby_id", "")
    if lobbyID.is_empty():
        return
    if CoopManager.is_session_active():
        return
    _log("Steam invite received — joining lobby %s" % lobbyID)
    CoopManager.coopUI.on_lobby_join_pressed(lobbyID)


func on_launch_invite_checked(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", { }) as Dictionary
    var lobbyID: String = data.get(&"lobby_id", "")
    if lobbyID.is_empty():
        return
    _log("Launch invite detected — joining lobby %s" % lobbyID)
    CoopManager.coopUI.on_lobby_join_pressed(lobbyID)


func set_rich_presence(key: String, value: String) -> void:
    if state != State.CONNECTED:
        return
    send_command("set_rich_presence", { "key": key, "value": value }, Callable())


func clear_rich_presence() -> void:
    if state != State.CONNECTED:
        return
    send_command("clear_rich_presence", {}, Callable())


func set_lobby_data(key: String, value: String, lobbyID: String = "") -> void:
    if state != State.CONNECTED:
        return
    var params: Dictionary = { "key": key, "value": value }
    if !lobbyID.is_empty():
        params["lobby_id"] = lobbyID
    send_command("set_lobby_data", params, Callable())


func get_lobby_data(lobbyID: String, key: String, callback: Callable) -> void:
    send_command("get_lobby_data", { "lobby_id": lobbyID, "key": key }, callback)


## Starts a Steam Networking Sockets P2P listen socket on the host.
func start_p2p_host(callback: Callable, enetPort: int = 9050) -> void:
    send_command("start_p2p_host", { "enet_port": enetPort }, callback)


## Connects to a host via Steam P2P and creates a local UDP tunnel.
## Returns the [code]tunnel_port[/code] that the game's ENet client should connect to.
func start_p2p_client(hostSteamID: String, callback: Callable) -> void:
    send_command("start_p2p_client", { "host_steam_id": hostSteamID }, callback)



func extract_file(resPath: String, userPath: String) -> void:
    var data: PackedByteArray = read_from_res(resPath)
    if data.is_empty():
        data = read_from_vmz(resPath)
    if data.is_empty():
        _log("Cannot read: %s" % resPath)
        return
    # Skip the write if destination already matches — saves several hundred ms
    # on cold launch (helper binary is ~5MB, steam dll ~300KB).
    if FileAccess.file_exists(userPath):
        var existing: FileAccess = FileAccess.open(userPath, FileAccess.READ)
        if existing != null:
            var existingSize: int = existing.get_length()
            existing.close()
            if existingSize == data.size():
                return
    var dst: FileAccess = FileAccess.open(userPath, FileAccess.WRITE)
    if dst == null:
        _log("Cannot write: %s" % userPath)
        return
    dst.store_buffer(data)
    dst.close()
    _log("Extracted: %s -> %s (%d bytes)" % [resPath, userPath, data.size()])


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
    if CoopManager == null || CoopManager.DEBUG:
        print("[SteamBridge] %s" % msg)
