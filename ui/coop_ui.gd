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

# World picker widgets
var worldPickerPanel: Control = null
var worldPickerList: VBoxContainer = null
var worldPickerVisible: bool = false

# New world dialog widgets
var newWorldPanel: Control = null
var newWorldNameInput: LineEdit = null
var newWorldDifficulty: int = 1
var newWorldSeason: int = 1
var diffButtons: Array[Button] = []
var seasonButtons: Array[Button] = []

# Menu-specific lobby browser (separate from F10 in-game panel)
var menuLobbyBrowser: Control = null
var menuLobbyList: VBoxContainer = null
var menuLobbyLabelPool: Array[Button] = []

const COOP_DIR: String = "user://coop/"
const META_FILE: String = "meta.cfg"
const SELECTED_COLOR: Color = Color(0.4, 0.8, 0.4)
const UNSELECTED_COLOR: Color = Color(0.7, 0.7, 0.7)

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

    var collectLogsBtn: Button = Button.new()
    collectLogsBtn.text = "Open Logs Folder"
    collectLogsBtn.pressed.connect(_on_collect_logs_pressed)
    vbox.add_child(collectLogsBtn)

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
            var worldLabel: String = _get_active_world_name()
            statusLabel.text = "Hosting — %s (%d peers)" % [worldLabel, currentPeerCount] if !worldLabel.is_empty() else "Hosting (%d peers)" % currentPeerCount
        2:
            var worldLabel: String = _get_active_world_name()
            statusLabel.text = "Connected — %s" % worldLabel if !worldLabel.is_empty() else "Connected"

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
    if _cm.is_session_active():
        return
    show_world_picker()


func on_direct_join_pressed() -> void:
    var address: String = addressInput.text if addressInput != null && !addressInput.text.is_empty() else "127.0.0.1"
    var port: int = _cm.DEFAULT_PORT
    if portInput != null && portInput.text.is_valid_int():
        port = clampi(portInput.text.to_int(), 1024, 65535)
    _cm.join_game(address, port)


func on_disconnect_pressed() -> void:
    _cm.disconnect_session()


## Copies godot.log + steam_helper.log to a timestamped folder and opens it.
func _on_collect_logs_pressed() -> void:
    if !is_instance_valid(_cm):
        return
    _cm.collect_logs()


## Shows a themed, menu-specific lobby browser (separate from the F10 in-game
## panel which has cluttered controls). Called when the user clicks
## Multiplayer → Browse Lobbies from the main menu.
func show_lobby_browser() -> void:
    _free_dialog(menuLobbyBrowser)
    menuLobbyBrowser = _make_menu_dialog_panel("Browse Lobbies", "Join a friend's game")
    add_child(menuLobbyBrowser)
    _wire_return_button(menuLobbyBrowser, hide_lobby_browser)

    var vbox: VBoxContainer = menuLobbyBrowser.get_node("VBox")

    var refreshBtn: Button = Button.new()
    refreshBtn.text = "Refresh"
    refreshBtn.custom_minimum_size = Vector2(0, 36)
    refreshBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    refreshBtn.pressed.connect(on_refresh_lobbies)
    vbox.add_child(refreshBtn)

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(0, 260)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    vbox.add_child(scroll)

    menuLobbyList = VBoxContainer.new()
    menuLobbyList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(menuLobbyList)
    menuLobbyLabelPool.clear()

    on_refresh_lobbies()


func hide_lobby_browser() -> void:
    _free_dialog(menuLobbyBrowser)
    menuLobbyBrowser = null
    _show_mp_submenu_if_on_menu()


func on_refresh_lobbies() -> void:
    if !_cm.steamBridge.is_ready():
        return
    _cm.steamBridge.list_lobbies(on_lobby_list_received)


func on_lobby_list_received(response: Dictionary) -> void:
    # Active list & pool: menu browser takes priority when visible, else F10 panel.
    var activePool: Array[Button] = menuLobbyLabelPool if menuLobbyBrowser != null else lobbyLabelPool

    for i: int in range(activePool.size()):
        activePool[i].hide()

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

    for i: int in range(lobbies.size(), activePool.size()):
        activePool[i].hide()


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


# ---------- World Picker ----------


## Reads the display name for the currently active co-op world from meta.cfg.
## Returns empty string if no world is active or meta is missing.
func _get_active_world_name() -> String:
    if _cm == null || _cm.worldId.is_empty():
        return ""
    var cfgPath: String = COOP_DIR + _cm.worldId + "/" + META_FILE
    if !FileAccess.file_exists(cfgPath):
        return _cm.worldId
    var cfg: ConfigFile = ConfigFile.new()
    if cfg.load(cfgPath) != OK:
        return _cm.worldId
    return cfg.get_value("world", "name", _cm.worldId)


## Creates an opaque dark stylebox so dialog panels don't show the panel behind them.
func _make_dialog_stylebox() -> StyleBoxFlat:
    var style: StyleBoxFlat = StyleBoxFlat.new()
    style.bg_color = Color(0.08, 0.08, 0.08, 0.97)
    style.border_color = Color(0.3, 0.3, 0.3, 1.0)
    style.border_width_left = 1
    style.border_width_right = 1
    style.border_width_top = 1
    style.border_width_bottom = 1
    style.content_margin_left = 12
    style.content_margin_right = 12
    style.content_margin_top = 10
    style.content_margin_bottom = 10
    return style


func show_world_picker() -> void:
    _free_dialog(worldPickerPanel)
    worldPickerPanel = _make_menu_dialog_panel("Host World", "Select a world to host")
    add_child(worldPickerPanel)
    _wire_return_button(worldPickerPanel, hide_world_picker)

    var vbox: VBoxContainer = worldPickerPanel.get_node("VBox")

    var newBtn: Button = Button.new()
    newBtn.text = "+ New World"
    newBtn.custom_minimum_size = Vector2(0, 36)
    newBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    newBtn.pressed.connect(show_new_world_dialog)
    vbox.add_child(newBtn)

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(0, 240)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    vbox.add_child(scroll)

    worldPickerList = VBoxContainer.new()
    worldPickerList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(worldPickerList)

    populate_world_list()

    worldPickerVisible = true


## Creates a full-screen menu scaffold matching the game's Modes/Settings style:
## [br] - Transparent Control covering full rect (captures input)
## [br] - Centered Header (font_size 20) + dim Subheader (alpha 0.5)
## [br] - Empty VBox named "VBox" below the header for custom content
## [br] - "← Return" button anchored bottom-center (256×40, connected via callback)
## Returns the root Control; callers add to VBox and wire the Return callback
## via [method _wire_return_button].
func _make_menu_dialog_panel(titleText: String, subtitleText: String) -> Control:
    var gameTheme: Theme = load("res://UI/Themes/Theme.tres")

    var root: Control = Control.new()
    root.name = "MenuDialog"
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_STOP
    if gameTheme != null:
        root.theme = gameTheme

    # Header: centered at top third of screen
    var header: Label = Label.new()
    header.name = "Header"
    header.text = titleText
    header.add_theme_font_size_override("font_size", 20)
    header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    header.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
    header.offset_left = -192
    header.offset_right = 192
    header.offset_top = 120
    header.offset_bottom = 160
    root.add_child(header)

    if !subtitleText.is_empty():
        var subheader: Label = Label.new()
        subheader.name = "Subheader"
        subheader.text = subtitleText
        subheader.modulate = Color(1, 1, 1, 0.5)
        subheader.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        subheader.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
        subheader.offset_left = -192
        subheader.offset_right = 192
        subheader.offset_top = 150
        subheader.offset_bottom = 180
        root.add_child(subheader)

    # Content VBox: centered, below the subheader
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.name = "VBox"
    vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
    vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
    vbox.custom_minimum_size = Vector2(420, 0)
    vbox.add_theme_constant_override("separation", 10)
    root.add_child(vbox)

    # Return button: anchored bottom-center, same size as game's Modes_Return
    var returnBtn: Button = Button.new()
    returnBtn.name = "ReturnBtn"
    returnBtn.text = "← Return"
    returnBtn.custom_minimum_size = Vector2(256, 40)
    returnBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    returnBtn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
    returnBtn.offset_left = -128
    returnBtn.offset_right = 128
    returnBtn.offset_top = -96
    returnBtn.offset_bottom = -56
    root.add_child(returnBtn)

    return root


## Wires the Return button on a menu dialog to the given callback.
func _wire_return_button(dialog: Control, callback: Callable) -> void:
    var returnBtn: Button = dialog.get_node_or_null("ReturnBtn")
    if returnBtn == null:
        return
    for conn: Dictionary in returnBtn.pressed.get_connections():
        returnBtn.pressed.disconnect(conn["callable"])
    returnBtn.pressed.connect(callback)


## Legacy shim — older callers passed the VBox; now the Return lives on root.
func _append_return_button(_vbox: VBoxContainer, _callback: Callable) -> void:
    # Return button is now part of the dialog scaffold. Callers should use
    # _wire_return_button(dialog, callback) instead.
    pass


## Hides the world picker. Returns to the Multiplayer submenu when opened from
## the main menu, otherwise just closes silently.
func hide_world_picker() -> void:
    _free_dialog(worldPickerPanel)
    worldPickerPanel = null
    worldPickerVisible = false
    _show_mp_submenu_if_on_menu()


## Frees a dialog panel along with its wrapper (if present).
func _free_dialog(dialog: Control) -> void:
    if dialog == null:
        return
    var wrapper: Node = dialog.get_meta(&"wrapper") if dialog.has_meta(&"wrapper") else null
    if wrapper != null && is_instance_valid(wrapper):
        wrapper.queue_free()
    else:
        dialog.queue_free()


## Shows the CoopMPSubmenu on the main menu. Used as the "Return" target for
## any coop dialog that was opened from Multiplayer.
func _show_mp_submenu_if_on_menu() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || scene.scene_file_path != "res://Scenes/Menu.tscn":
        return
    var submenu: Node = scene.get_node_or_null("CoopMPSubmenu")
    var main: Node = scene.get_node_or_null("Main")
    if submenu != null:
        submenu.show()
    elif main != null:
        # Fallback if submenu is missing
        main.show()


## When a coop dialog is cancelled from the main menu, restore Main visibility
## so the player isn't left staring at an empty screen.
func _restore_main_menu_if_open() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || scene.scene_file_path != "res://Scenes/Menu.tscn":
        return
    var main: Node = scene.get_node_or_null("Main")
    if main != null:
        main.show()


func populate_world_list() -> void:
    if worldPickerList == null:
        return

    if !DirAccess.dir_exists_absolute(COOP_DIR):
        _add_empty_label()
        return

    var dir: DirAccess = DirAccess.open(COOP_DIR)
    if dir == null:
        _add_empty_label()
        return

    # Collect worlds with metadata
    var worlds: Array[Dictionary] = []
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if dir.current_is_dir() && entry != "." && entry != "..":
            var worldDir: String = COOP_DIR + entry + "/"
            if FileAccess.file_exists(worldDir + "World.tres"):
                var meta: Dictionary = _read_world_meta(worldDir, entry)
                worlds.append(meta)
        entry = dir.get_next()
    dir.list_dir_end()

    if worlds.is_empty():
        _add_empty_label()
        return

    # Sort by last_played descending (most recent first)
    worlds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.get("last_played", 0) > b.get("last_played", 0))

    for world: Dictionary in worlds:
        var row: HBoxContainer = HBoxContainer.new()
        row.add_theme_constant_override("separation", 4)
        worldPickerList.add_child(row)

        var btn: Button = _make_two_line_row_button(world["name"], _format_world_meta(world))
        btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        btn.pressed.connect(on_world_selected.bind(world["id"]))
        row.add_child(btn)

        var delBtn: Button = Button.new()
        delBtn.text = "×"
        delBtn.custom_minimum_size = Vector2(40, 56)
        delBtn.mouse_filter = Control.MOUSE_FILTER_STOP
        delBtn.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
        delBtn.add_theme_font_size_override("font_size", 18)
        delBtn.pressed.connect(on_delete_world_pressed.bind(world["id"], world["name"]))
        row.add_child(delBtn)


## Creates a clickable button with two stacked labels (title + metadata).
## The Button handles click/hover; child labels render on top of its text area.
func _make_two_line_row_button(titleText: String, metaText: String) -> Button:
    var btn: Button = Button.new()
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    btn.custom_minimum_size = Vector2(0, 56)
    btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 12
    vbox.offset_right = -12
    vbox.offset_top = 8
    vbox.offset_bottom = -8
    vbox.add_theme_constant_override("separation", 2)
    btn.add_child(vbox)

    var titleLabel: Label = Label.new()
    titleLabel.text = titleText
    titleLabel.add_theme_font_size_override("font_size", 15)
    titleLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    vbox.add_child(titleLabel)

    var metaLabel: Label = Label.new()
    metaLabel.text = metaText
    metaLabel.add_theme_font_size_override("font_size", 11)
    metaLabel.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
    metaLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    vbox.add_child(metaLabel)

    return btn


func _add_empty_label() -> void:
    var emptyLabel: Label = Label.new()
    emptyLabel.text = "No existing worlds"
    emptyLabel.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
    emptyLabel.add_theme_font_size_override("font_size", 13)
    emptyLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    emptyLabel.custom_minimum_size = Vector2(0, 80)
    worldPickerList.add_child(emptyLabel)


func _read_world_meta(worldDir: String, dirName: String) -> Dictionary:
    var meta: Dictionary = {"id": dirName, "name": dirName, "last_played": 0}

    # Read meta.cfg if it exists
    var cfg: ConfigFile = ConfigFile.new()
    if cfg.load(worldDir + META_FILE) == OK:
        meta["name"] = cfg.get_value("world", "name", dirName)
        meta["last_played"] = cfg.get_value("world", "last_played", 0)

    # Read World.tres for game data
    var worldSave: Resource = load(worldDir + "World.tres")
    if worldSave != null:
        meta["day"] = worldSave.get("day") if worldSave.get("day") != null else 1
        meta["season"] = worldSave.get("season") if worldSave.get("season") != null else 1
        meta["difficulty"] = worldSave.get("difficulty") if worldSave.get("difficulty") != null else 1

    meta["players"] = _count_players_in_world(worldDir + "players/")
    return meta


## Returns just the metadata line (day, difficulty, season, player count, last played)
## for use below the world name in two-line list rows.
func _format_world_meta(world: Dictionary) -> String:
    var day: int = world.get("day", 1)
    var season: int = world.get("season", 1)
    var diff: int = world.get("difficulty", 1)
    var players: int = world.get("players", 0)
    var lastPlayed: int = world.get("last_played", 0)

    var seasonText: String = "Summer" if season == 1 else "Winter"
    var diffText: String = "Normal"
    match diff:
        2: diffText = "Hard"
        3: diffText = "Permadeath"

    var playerText: String = "1 player" if players == 1 else "%d players" % players
    var base: String = "Day %d • %s • %s • %s" % [day, diffText, seasonText, playerText]

    if lastPlayed > 0:
        var now: int = int(Time.get_unix_time_from_system())
        var elapsed: int = now - lastPlayed
        var elapsedText: String = ""
        if elapsed < 3600:
            elapsedText = "%dm ago" % max(1, elapsed / 60)
        elif elapsed < 86400:
            elapsedText = "%dh ago" % (elapsed / 3600)
        else:
            elapsedText = "%dd ago" % (elapsed / 86400)
        base += " • " + elapsedText

    return base


func _format_world_label(world: Dictionary) -> String:
    var name: String = world.get("name", "Unknown")
    var day: int = world.get("day", 1)
    var season: int = world.get("season", 1)
    var diff: int = world.get("difficulty", 1)
    var players: int = world.get("players", 0)
    var lastPlayed: int = world.get("last_played", 0)

    var seasonText: String = "Summer" if season == 1 else "Winter"
    var diffText: String = "Normal"
    match diff:
        2: diffText = "Hard"
        3: diffText = "Permadeath"

    var timeText: String = ""
    if lastPlayed > 0:
        var now: int = int(Time.get_unix_time_from_system())
        var elapsed: int = now - lastPlayed
        if elapsed < 3600:
            timeText = " — %dm ago" % (elapsed / 60)
        elif elapsed < 86400:
            timeText = " — %dh ago" % (elapsed / 3600)
        else:
            timeText = " — %dd ago" % (elapsed / 86400)

    return "%s — %s Day %d, %s, %d player(s)%s" % [name, seasonText, day, diffText, players, timeText]


func _count_players_in_world(playersDir: String) -> int:
    if !DirAccess.dir_exists_absolute(playersDir):
        return 0
    var dir: DirAccess = DirAccess.open(playersDir)
    if dir == null:
        return 0
    var count: int = 0
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if dir.current_is_dir() && entry != "." && entry != "..":
            count += 1
        entry = dir.get_next()
    dir.list_dir_end()
    return count


# ---------- New World Dialog ----------


func show_new_world_dialog() -> void:
    # Close the world picker first (this is a forward transition, not a cancel).
    _free_dialog(worldPickerPanel)
    worldPickerPanel = null
    worldPickerVisible = false

    newWorldDifficulty = 1
    newWorldSeason = 1
    diffButtons.clear()
    seasonButtons.clear()

    newWorldPanel = _make_menu_dialog_panel("New World", "Set up your co-op world")
    add_child(newWorldPanel)
    _wire_return_button(newWorldPanel, on_new_world_back)

    var vbox: VBoxContainer = newWorldPanel.get_node("VBox")

    var nameLabel: Label = Label.new()
    nameLabel.text = "World Name"
    nameLabel.add_theme_font_size_override("font_size", 14)
    vbox.add_child(nameLabel)

    newWorldNameInput = LineEdit.new()
    newWorldNameInput.placeholder_text = "My World"
    newWorldNameInput.max_length = 32
    newWorldNameInput.mouse_filter = Control.MOUSE_FILTER_STOP
    newWorldNameInput.custom_minimum_size = Vector2(0, 32)
    vbox.add_child(newWorldNameInput)

    var diffLabel: Label = Label.new()
    diffLabel.text = "Difficulty"
    diffLabel.add_theme_font_size_override("font_size", 14)
    vbox.add_child(diffLabel)

    var diffRow: HBoxContainer = HBoxContainer.new()
    diffRow.add_theme_constant_override("separation", 8)
    vbox.add_child(diffRow)

    for pair: Array in [[1, "Normal"], [2, "Hard"], [3, "Permadeath"]]:
        var btn: Button = Button.new()
        btn.text = pair[1]
        btn.custom_minimum_size = Vector2(0, 36)
        btn.add_theme_font_size_override("font_size", 14)
        btn.mouse_filter = Control.MOUSE_FILTER_STOP
        btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        btn.pressed.connect(_on_difficulty_selected.bind(pair[0]))
        diffRow.add_child(btn)
        diffButtons.append(btn)

    var seasonLabel: Label = Label.new()
    seasonLabel.text = "Season"
    seasonLabel.add_theme_font_size_override("font_size", 14)
    vbox.add_child(seasonLabel)

    var seasonRow: HBoxContainer = HBoxContainer.new()
    seasonRow.add_theme_constant_override("separation", 8)
    vbox.add_child(seasonRow)

    for pair: Array in [[1, "Summer"], [2, "Winter"]]:
        var btn: Button = Button.new()
        btn.text = pair[1]
        btn.custom_minimum_size = Vector2(0, 36)
        btn.add_theme_font_size_override("font_size", 14)
        btn.mouse_filter = Control.MOUSE_FILTER_STOP
        btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        btn.pressed.connect(_on_season_selected.bind(pair[0]))
        seasonRow.add_child(btn)
        seasonButtons.append(btn)

    _update_selection_colors()

    var createBtn: Button = Button.new()
    createBtn.text = "Create"
    createBtn.custom_minimum_size = Vector2(0, 40)
    createBtn.add_theme_font_size_override("font_size", 16)
    createBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    createBtn.pressed.connect(on_create_world_confirmed)
    vbox.add_child(createBtn)


func _on_difficulty_selected(diff: int) -> void:
    newWorldDifficulty = diff
    _update_selection_colors()


func _on_season_selected(season: int) -> void:
    newWorldSeason = season
    _update_selection_colors()


func _update_selection_colors() -> void:
    for i: int in diffButtons.size():
        var btn: Button = diffButtons[i]
        if i + 1 == newWorldDifficulty:
            btn.add_theme_color_override("font_color", SELECTED_COLOR)
        else:
            btn.add_theme_color_override("font_color", UNSELECTED_COLOR)

    for i: int in seasonButtons.size():
        var btn: Button = seasonButtons[i]
        if i + 1 == newWorldSeason:
            btn.add_theme_color_override("font_color", SELECTED_COLOR)
        else:
            btn.add_theme_color_override("font_color", UNSELECTED_COLOR)


func on_create_world_confirmed() -> void:
    var worldName: String = newWorldNameInput.text.strip_edges()
    if worldName.is_empty():
        worldName = "World"

    var worldId: String = "world_%d" % Time.get_unix_time_from_system()

    # Write meta.cfg
    var worldDir: String = COOP_DIR + worldId + "/"
    DirAccess.make_dir_recursive_absolute(worldDir)
    _write_world_meta(worldDir, worldName)

    # Close dialog and host
    _free_dialog(newWorldPanel)
    newWorldPanel = null

    _cm.worldId = worldId
    _cm.host_game()

    # NewGame with selected difficulty/season will be called by _auto_load_game
    # when the host transitions from menu to game. We store the settings
    # so coop_manager can pass them to Loader.NewGame().
    _cm.set_meta(&"new_world_difficulty", newWorldDifficulty)
    _cm.set_meta(&"new_world_season", newWorldSeason)


func on_new_world_back() -> void:
    _free_dialog(newWorldPanel)
    newWorldPanel = null
    show_world_picker()


func on_world_selected(worldId: String) -> void:
    hide_world_picker()
    _update_world_last_played(worldId)
    _cm.worldId = worldId
    _cm.host_game()


# ---------- Delete World ----------


func on_delete_world_pressed(worldId: String, worldName: String) -> void:
    # Replace the world list with a confirmation prompt
    for child: Node in worldPickerList.get_children():
        child.queue_free()

    var confirmLabel: Label = Label.new()
    confirmLabel.text = "Delete \"%s\"?" % worldName
    worldPickerList.add_child(confirmLabel)

    var warnLabel: Label = Label.new()
    warnLabel.text = "All player saves will be lost."
    warnLabel.add_theme_font_size_override("font_size", 12)
    warnLabel.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
    worldPickerList.add_child(warnLabel)

    var row: HBoxContainer = HBoxContainer.new()
    worldPickerList.add_child(row)

    var yesBtn: Button = Button.new()
    yesBtn.text = "Delete"
    yesBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    yesBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    yesBtn.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
    yesBtn.pressed.connect(_confirm_delete_world.bind(worldId))
    row.add_child(yesBtn)

    var noBtn: Button = Button.new()
    noBtn.text = "Cancel"
    noBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    noBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    noBtn.pressed.connect(_cancel_delete_world)
    row.add_child(noBtn)


func _confirm_delete_world(worldId: String) -> void:
    var worldDir: String = COOP_DIR + worldId + "/"
    _recursive_delete(worldDir)
    # Refresh the list
    for child: Node in worldPickerList.get_children():
        child.queue_free()
    populate_world_list()


func _cancel_delete_world() -> void:
    for child: Node in worldPickerList.get_children():
        child.queue_free()
    populate_world_list()


func _recursive_delete(path: String) -> void:
    var dir: DirAccess = DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry == "." || entry == "..":
            entry = dir.get_next()
            continue
        var fullPath: String = path + entry
        if dir.current_is_dir():
            _recursive_delete(fullPath + "/")
            DirAccess.remove_absolute(fullPath)
        else:
            DirAccess.remove_absolute(fullPath)
        entry = dir.get_next()
    dir.list_dir_end()
    DirAccess.remove_absolute(path)


# ---------- World Meta Helpers ----------


func _write_world_meta(worldDir: String, worldName: String) -> void:
    var cfg: ConfigFile = ConfigFile.new()
    cfg.set_value("world", "name", worldName)
    cfg.set_value("world", "created", int(Time.get_unix_time_from_system()))
    cfg.set_value("world", "last_played", int(Time.get_unix_time_from_system()))
    cfg.save(worldDir + META_FILE)


func _update_world_last_played(worldId: String) -> void:
    var worldDir: String = COOP_DIR + worldId + "/"
    var cfg: ConfigFile = ConfigFile.new()
    cfg.load(worldDir + META_FILE)
    cfg.set_value("world", "last_played", int(Time.get_unix_time_from_system()))
    cfg.save(worldDir + META_FILE)


func get_pooled_lobby_button(idx: int) -> Button:
    # When the menu browser is open, pool buttons go there; otherwise F10 panel.
    var useMenu: bool = menuLobbyBrowser != null
    var pool: Array[Button] = menuLobbyLabelPool if useMenu else lobbyLabelPool
    var container: VBoxContainer = menuLobbyList if useMenu else lobbyList

    if idx < pool.size():
        pool[idx].show()
        return pool[idx]

    var btn: Button = Button.new()
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    if container != null:
        container.add_child(btn)
    pool.append(btn)
    return btn
