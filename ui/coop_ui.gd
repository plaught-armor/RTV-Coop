## Host/join panel for the co-op mod.
## [kbd]F9[/kbd] toggles the panel. [kbd]F10[/kbd] quick-hosts.
## Primary UI is Steam lobby browser. ENet direct-connect shown only in DEBUG mode.
extends Control

var _cm: Node



var panel: PanelContainer = null
var statusLabel: Label = null
var panelVisible: bool = false
var lastPeerCount: int = -1
var lastConnectionState: int = -1
var playerLabelPool: Array[HBoxContainer] = []

# Steam lobby widgets
var lobbyList: VBoxContainer = null
var lobbyLabelPool: Array[Button] = []

# Friend invite widgets
var friendScroll: ScrollContainer = null
var friendList: VBoxContainer = null
var friendLabelPool: Array[HBoxContainer] = []
var inviteBtn: Button = null
var friendsVisible: bool = false

# ENet debug widgets (only created in DEBUG mode)
var addressInput: LineEdit = null
var portInput: LineEdit = null

# Shared
var playerList: VBoxContainer = null


func init_manager(manager: Node) -> void:
    _cm = manager
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
            _cm.panelOpen = panelVisible
            if panelVisible:
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            else:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
        KEY_F10:
            on_host_pressed()
        KEY_F11:
            if _cm.DEBUG:
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

    inviteBtn = Button.new()
    inviteBtn.text = "Invite"
    inviteBtn.pressed.connect(on_invite_pressed)
    btnRow.add_child(inviteBtn)

    lobbyList = VBoxContainer.new()
    vbox.add_child(lobbyList)

    friendScroll = ScrollContainer.new()
    friendScroll.custom_minimum_size = Vector2(0, 200)
    friendScroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    friendScroll.hide()
    vbox.add_child(friendScroll)

    friendList = VBoxContainer.new()
    friendList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    friendScroll.add_child(friendList)

    # ENet debug section (DEBUG only)
    if _cm.DEBUG:
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
        portInput.placeholder_text = str(_cm.DEFAULT_PORT)
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
    if !panelVisible || _cm == null:
        return
    var currentState: int = 0
    var currentPeerCount: int = 0
    if _cm.isActive:
        currentPeerCount = _cm.connectedPeers.size()
        currentState = 1 if _cm.isHost else 2

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

    if _cm.isActive:
        var localRow: HBoxContainer = get_pooled_player_row(idx)
        idx += 1
        var localAvatar: TextureRect = localRow.get_child(0)
        var localLabel: Label = localRow.get_child(1)
        localLabel.text = "%s (You)" % _cm.get_local_name()
        var localTex: ImageTexture = _cm.avatarCache.get(_cm.steamBridge.localSteamID)
        if localTex != null:
            localAvatar.texture = localTex
            localAvatar.show()
        else:
            localAvatar.hide()

        for peerId: int in _cm.connectedPeers:
            var row: HBoxContainer = get_pooled_player_row(idx)
            idx += 1
            var avatar: TextureRect = row.get_child(0)
            var label: Label = row.get_child(1)
            label.text = _cm.get_peer_name(peerId)
            var tex: ImageTexture = _cm.get_peer_avatar(peerId)
            if tex != null:
                avatar.texture = tex
                avatar.show()
            else:
                avatar.hide()

    for i: int in range(idx, playerLabelPool.size()):
        playerLabelPool[i].hide()


func get_pooled_player_row(idx: int) -> HBoxContainer:
    if idx < playerLabelPool.size():
        playerLabelPool[idx].show()
        return playerLabelPool[idx]

    var row: HBoxContainer = HBoxContainer.new()
    var avatar: TextureRect = TextureRect.new()
    avatar.custom_minimum_size = Vector2(24, 24)
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    row.add_child(avatar)

    var label: Label = Label.new()
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(label)

    playerList.add_child(row)
    playerLabelPool.append(row)
    return row

# ---------- Helpers ----------


## Returns true if the current scene is a gameplay map (has Core/Controller).
## Closes the panel, unfreezes the game, and recaptures the mouse.
func close_panel() -> void:
    if !panelVisible:
        return
    panelVisible = false
    panel.visible = false
    _cm.panelOpen = false
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_in_gameplay() -> bool:
    var scene: Node = get_tree().current_scene
    return is_instance_valid(scene) && scene.get_node_or_null("Core/Controller") != null

# ---------- Actions ----------


func on_host_pressed() -> void:
    _cm.host_game()


func on_direct_join_pressed() -> void:
    var address: String = addressInput.text if addressInput != null && !addressInput.text.is_empty() else "127.0.0.1"
    var port: int = _cm.DEFAULT_PORT
    if portInput != null && portInput.text.is_valid_int():
        port = clampi(portInput.text.to_int(), 1024, 65535)
    _cm.join_game(address, port)


func on_disconnect_pressed() -> void:
    _cm.disconnect_session()


func on_refresh_lobbies() -> void:
    if !_cm.steamBridge.is_ready():
        return
    _cm.steamBridge.list_lobbies(on_lobby_list_received)


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
        var mapName: String = lobby.get("map", "")
        if mapName.is_empty():
            btn.text = "%s (%d/%d)" % [hostName, players, maxPlayers]
        else:
            btn.text = "%s — %s (%d/%d)" % [hostName, mapName, players, maxPlayers]
        var lobbyID: String = lobby.get("lobby_id", "")
        for conn: Dictionary in btn.pressed.get_connections():
            btn.pressed.disconnect(conn["callable"])
        btn.pressed.connect(on_lobby_join_pressed.bind(lobbyID))

    for i: int in range(lobbies.size(), lobbyLabelPool.size()):
        lobbyLabelPool[i].hide()


func on_lobby_join_pressed(lobbyID: String) -> void:
    _cm.steamBridge.join_lobby(lobbyID, on_lobby_joined)


func on_lobby_joined(response: Dictionary) -> void:
    if !response.get("ok", false):
        return
    var data: Dictionary = response.get("data", { })
    var hostSteamID: String = data.get("host_steam_id", "")
    var lobbyID: String = data.get("lobby_id", "")
    if hostSteamID.is_empty():
        _cm._log("Lobby has no host Steam ID")
        return
    _cm.currentLobbyID = lobbyID
    _cm._log("Lobby joined — starting P2P tunnel to host %s" % hostSteamID)
    # Read host state to decide if we should auto-load into the game
    if !lobbyID.is_empty():
        _cm.steamBridge.get_lobby_data(lobbyID, "state", _on_host_state_received)
    _cm.steamBridge.start_p2p_client(hostSteamID, _cm.on_p2p_tunnel_ready)


func _on_host_state_received(response: Dictionary) -> void:
    if !response.get("ok", false):
        return
    var data: Dictionary = response.get("data", {})
    var hostState: String = data.get("value", "")
    _cm._log("Host lobby state: %s" % hostState)
    if hostState == "in_game":
        _cm.pendingAutoJoin = true


func on_invite_pressed() -> void:
    if !_cm.steamBridge.is_ready():
        return
    if !_cm.isActive:
        return
    friendsVisible = !friendsVisible
    friendScroll.visible = friendsVisible
    if friendsVisible:
        _cm.steamBridge.get_friends(on_friends_received)


func on_friends_received(response: Dictionary) -> void:
    for i: int in range(friendLabelPool.size()):
        friendLabelPool[i].hide()

    if !response.get("ok", false):
        return

    var friends: Array = response.get("data", [])
    for i: int in range(friends.size()):
        var friend: Dictionary = friends[i]
        var row: HBoxContainer = get_pooled_friend_row(i)
        var avatar: TextureRect = row.get_child(0)
        var nameLabel: Label = row.get_child(1)
        var btn: Button = row.get_child(2)
        var friendName: String = friend.get("name", "Unknown")
        var state: int = friend.get("state", 0)
        var gameID: String = friend.get("game_id", "")
        var inGame: bool = !gameID.is_empty()

        var stateText: String = ""
        var nameColor: Color
        if inGame:
            stateText = " (In-Game)"
            nameColor = Color("#90ba3c")
        else:
            match state:
                1:
                    stateText = ""
                    nameColor = Color("#57cbde")
                2:
                    stateText = " (Busy)"
                    nameColor = Color("#57cbde", 0.5)
                3:
                    stateText = " (Away)"
                    nameColor = Color("#57cbde", 0.5)
                4:
                    stateText = " (Snooze)"
                    nameColor = Color("#57cbde", 0.4)
                _:
                    stateText = ""
                    nameColor = Color("#57cbde")

        nameLabel.text = "%s%s" % [friendName, stateText]
        nameLabel.add_theme_color_override("font_color", nameColor)

        # Fetch avatar via binary channel (faster than inline base64)
        var steamID: String = friend.get("steam_id", "")
        if steamID in _cm.avatarCache:
            avatar.texture = _cm.avatarCache[steamID]
            avatar.show()
        elif !steamID.is_empty():
            _cm.fetch_avatar(steamID)
            avatar.texture = null
            avatar.hide()
        else:
            avatar.texture = null
            avatar.hide()

        for conn: Dictionary in btn.pressed.get_connections():
            btn.pressed.disconnect(conn["callable"])
        btn.pressed.connect(on_invite_friend_pressed.bind(steamID, friendName))

    for i: int in range(friends.size(), friendLabelPool.size()):
        friendLabelPool[i].hide()


func on_invite_friend_pressed(steamID: String, friendName: String) -> void:
    _cm.steamBridge.invite_friend(steamID, on_invite_sent.bind(friendName))


func on_invite_sent(response: Dictionary, friendName: String) -> void:
    if response.get("ok", false):
        _cm._log("Invite sent to %s" % friendName)
    else:
        _cm._log("Invite failed: %s" % response.get("error", "unknown"))


func get_pooled_friend_row(idx: int) -> HBoxContainer:
    if idx < friendLabelPool.size():
        friendLabelPool[idx].show()
        return friendLabelPool[idx]

    var row: HBoxContainer = HBoxContainer.new()

    var avatar: TextureRect = TextureRect.new()
    avatar.custom_minimum_size = Vector2(24, 24)
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    row.add_child(avatar)

    var nameLabel: Label = Label.new()
    nameLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(nameLabel)

    var btn: Button = Button.new()
    btn.text = "Invite"
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(btn)

    friendList.add_child(row)
    friendLabelPool.append(row)
    return row


func get_pooled_lobby_button(idx: int) -> Button:
    if idx < lobbyLabelPool.size():
        lobbyLabelPool[idx].show()
        return lobbyLabelPool[idx]

    var btn: Button = Button.new()
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    lobbyList.add_child(btn)
    lobbyLabelPool.append(btn)
    return btn
