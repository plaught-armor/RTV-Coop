## Host/join panel for the co-op mod.
## [kbd]F9[/kbd] toggles the panel. [kbd]F10[/kbd] quick-hosts.
## Primary UI is Steam lobby browser. ENet direct-connect shown only in DEBUG mode.
extends Control

var panel: PanelContainer = null
var statusLabel: Label = null
var panelVisible: bool = false
var lastPeerCount: int = -1
var lastConnectionState: int = -1
var playerLabelPool: Array[Label] = []

# Steam lobby widgets
var lobbyList: VBoxContainer = null
var lobbyLabelPool: Array[Button] = []

# ENet debug widgets (only created in DEBUG mode)
var addressInput: LineEdit = null
var portInput: LineEdit = null

# Shared
var playerList: VBoxContainer = null


func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    build_ui()
    panel.hide()


func _input(event: InputEvent) -> void:
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if !is_in_gameplay():
        return

    match event.keycode:
        KEY_INSERT:
            panelVisible = !panelVisible
            panel.visible = panelVisible
            CoopManager.panelOpen = panelVisible
            if panelVisible:
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            else:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
        KEY_F10:
            on_host_pressed()
        KEY_F11:
            if CoopManager.DEBUG:
                on_direct_join_pressed()


func build_ui() -> void:
    panel = PanelContainer.new()
    panel.custom_minimum_size = Vector2(340, 400)
    panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
    panel.grow_vertical = Control.GROW_DIRECTION_BOTH
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(panel)

    var vbox: VBoxContainer = VBoxContainer.new()
    panel.add_child(vbox)

    var titleLabel: Label = Label.new()
    titleLabel.text = "Co-op"
    titleLabel.add_theme_font_size_override("font_size", 18)
    vbox.add_child(titleLabel)

    statusLabel = Label.new()
    statusLabel.text = "Disconnected"
    vbox.add_child(statusLabel)

    vbox.add_child(HSeparator.new())

    # Steam lobby section (always visible)
    var steamLabel: Label = Label.new()
    steamLabel.text = "Steam Lobbies"
    vbox.add_child(steamLabel)

    var btnRow: HBoxContainer = HBoxContainer.new()
    vbox.add_child(btnRow)

    var hostBtn: Button = Button.new()
    hostBtn.text = "Host (F10)"
    hostBtn.pressed.connect(on_host_pressed)
    btnRow.add_child(hostBtn)

    var refreshBtn: Button = Button.new()
    refreshBtn.text = "Refresh"
    refreshBtn.pressed.connect(on_refresh_lobbies)
    btnRow.add_child(refreshBtn)

    lobbyList = VBoxContainer.new()
    vbox.add_child(lobbyList)

    # ENet debug section (DEBUG only)
    if CoopManager.DEBUG:
        vbox.add_child(HSeparator.new())

        var debugLabel: Label = Label.new()
        debugLabel.text = "Direct Connect (DEBUG)"
        vbox.add_child(debugLabel)

        var addrRow: HBoxContainer = HBoxContainer.new()
        vbox.add_child(addrRow)

        var addrLabel: Label = Label.new()
        addrLabel.text = "IP:"
        addrRow.add_child(addrLabel)

        addressInput = LineEdit.new()
        addressInput.placeholder_text = "127.0.0.1"
        addressInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        addressInput.mouse_filter = Control.MOUSE_FILTER_STOP
        addrRow.add_child(addressInput)

        var portRow: HBoxContainer = HBoxContainer.new()
        vbox.add_child(portRow)

        var portLabel: Label = Label.new()
        portLabel.text = "Port:"
        portRow.add_child(portLabel)

        portInput = LineEdit.new()
        portInput.placeholder_text = str(CoopManager.DEFAULT_PORT)
        portInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        portInput.mouse_filter = Control.MOUSE_FILTER_STOP
        portRow.add_child(portInput)

        var joinBtn: Button = Button.new()
        joinBtn.text = "Direct Join"
        joinBtn.pressed.connect(on_direct_join_pressed)
        vbox.add_child(joinBtn)

    vbox.add_child(HSeparator.new())

    var disconnectBtn: Button = Button.new()
    disconnectBtn.text = "Disconnect"
    disconnectBtn.pressed.connect(on_disconnect_pressed)
    vbox.add_child(disconnectBtn)

    vbox.add_child(HSeparator.new())

    var playersLabel: Label = Label.new()
    playersLabel.text = "Connected Players:"
    vbox.add_child(playersLabel)

    playerList = VBoxContainer.new()
    vbox.add_child(playerList)


func _process(_delta: float) -> void:
    if !panelVisible:
        return
    var currentState: int = 0
    var currentPeerCount: int = 0
    if CoopManager.isActive:
        currentPeerCount = CoopManager.connectedPeers.size()
        currentState = 1 if CoopManager.isHost else 2

    if currentState == lastConnectionState && currentPeerCount == lastPeerCount:
        return
    lastConnectionState = currentState
    lastPeerCount = currentPeerCount

    match currentState:
        0:
            statusLabel.text = "Disconnected"
        1:
            statusLabel.text = "Hosting (%d peers)" % currentPeerCount
        2:
            statusLabel.text = "Connected"

    update_player_list()


func update_player_list() -> void:
    var idx: int = 0

    if CoopManager.isActive:
        var localLabel: Label = get_pooled_player_label(idx)
        idx += 1
        localLabel.text = "  %s (You)" % CoopManager.get_local_name()

        for peerId: int in CoopManager.connectedPeers:
            var label: Label = get_pooled_player_label(idx)
            idx += 1
            label.text = "  %s" % CoopManager.get_peer_name(peerId)

    for i: int in range(idx, playerLabelPool.size()):
        playerLabelPool[i].hide()


func get_pooled_player_label(idx: int) -> Label:
    if idx < playerLabelPool.size():
        playerLabelPool[idx].show()
        return playerLabelPool[idx]

    var label: Label = Label.new()
    playerList.add_child(label)
    playerLabelPool.append(label)
    return label

# ---------- Helpers ----------


## Returns true if the current scene is a gameplay map (has Core/Controller).
## Closes the panel, unfreezes the game, and recaptures the mouse.
func close_panel() -> void:
    if !panelVisible:
        return
    panelVisible = false
    panel.visible = false
    CoopManager.panelOpen = false
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_in_gameplay() -> bool:
    var scene: Node = get_tree().current_scene
    return is_instance_valid(scene) && scene.get_node_or_null("Core/Controller") != null

# ---------- Actions ----------


func on_host_pressed() -> void:
    CoopManager.host_game()


func on_direct_join_pressed() -> void:
    var address: String = addressInput.text if addressInput != null && !addressInput.text.is_empty() else "127.0.0.1"
    var port: int = CoopManager.DEFAULT_PORT
    if portInput != null && portInput.text.is_valid_int():
        port = clampi(portInput.text.to_int(), 1024, 65535)
    CoopManager.join_game(address, port)


func on_disconnect_pressed() -> void:
    CoopManager.disconnect_session()


func on_refresh_lobbies() -> void:
    if !CoopManager.steamBridge.is_ready():
        return
    CoopManager.steamBridge.list_lobbies(on_lobby_list_received)


func on_lobby_list_received(response: Dictionary) -> void:
    for i: int in range(lobbyLabelPool.size()):
        lobbyLabelPool[i].hide()

    if !response.get("ok", false):
        return

    var lobbies: Array = response.get("data", [])
    for i: int in range(lobbies.size()):
        var lobby: Dictionary = lobbies[i]
        var btn: Button = get_pooled_lobby_button(i)
        var hostName: String = lobby.get("host_name", "Unknown")
        var players: int = lobby.get("players", 0)
        var maxPlayers: int = lobby.get("max_players", 0)
        btn.text = "%s (%d/%d)" % [hostName, players, maxPlayers]
        var lobbyID: String = lobby.get("lobby_id", "")
        for conn: Dictionary in btn.pressed.get_connections():
            btn.pressed.disconnect(conn["callable"])
        btn.pressed.connect(on_lobby_join_pressed.bind(lobbyID))

    for i: int in range(lobbies.size(), lobbyLabelPool.size()):
        lobbyLabelPool[i].hide()


func on_lobby_join_pressed(lobbyID: String) -> void:
    CoopManager.steamBridge.join_lobby(lobbyID, on_lobby_joined)


func on_lobby_joined(response: Dictionary) -> void:
    if !response.get("ok", false):
        return
    var data: Dictionary = response.get("data", { })
    var hostSteamID: String = data.get("host_steam_id", "")
    if hostSteamID.is_empty():
        CoopManager._log("Lobby has no host Steam ID")
        return
    CoopManager._log("Lobby joined — starting P2P tunnel to host %s" % hostSteamID)
    CoopManager.steamBridge.start_p2p_client(hostSteamID, CoopManager.on_p2p_tunnel_ready)


func get_pooled_lobby_button(idx: int) -> Button:
    if idx < lobbyLabelPool.size():
        lobbyLabelPool[idx].show()
        return lobbyLabelPool[idx]

    var btn: Button = Button.new()
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    lobbyList.add_child(btn)
    lobbyLabelPool.append(btn)
    return btn
