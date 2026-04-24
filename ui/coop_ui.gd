## Host/join panel for the co-op mod.
## [kbd]F11[/kbd] toggles the in-game coop panel (host/join/browse/disconnect).
## Primary UI is Steam lobby browser. ENet direct-connect reachable from the panel.
extends Control




var panel: PanelContainer = null
var statusLabel: Label = null
var panelVisible: bool = false
var lastPeerCount: int = -1
var lastConnectionState: int = -1
var playerLabelPool: Array[HBoxContainer] = []

# Steam lobby widgets
var lobbyLabelPool: Array[Button] = []
var _hostRow: HBoxContainer = null
var _ipJoinRow: HBoxContainer = null
var _inlineAddrInput: LineEdit = null
var _inlinePortInput: LineEdit = null
var _subtitleLabel: Label = null
var _modeLabel: Label = null
var _addressRow: HBoxContainer = null
var _addressLabel: Label = null
var _sessionInfoRow: HBoxContainer = null
var _nameRow: HBoxContainer = null
var _nameInput: LineEdit = null
var _friendsCol: VBoxContainer = null
var _dimBackground: ColorRect = null
var _pausedLabel: Label = null
var _bottomControlsCol: VBoxContainer = null

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

# Scene-node NodePath constants. Using literal ^"..." avoids per-call String→NodePath
# re-parsing and keeps lookups type-safe with Godot 4.6's stricter Node APIs.
const PATH_CONTROLLER: NodePath = ^"Core/Controller"
const PATH_MENU_SUBMENU: NodePath = ^"CoopMPSubmenu"
const PATH_MENU_MAIN: NodePath = ^"Main"
const PATH_LOADER_ABS: NodePath = ^"/root/Loader"

# Direct-connect dialog
var directJoinPanel: Control = null
var djAddressInput: LineEdit = null
var djPortInput: LineEdit = null

# Lobby dialog (shared by Steam + IP host flows)
var lobbyPanel: Control = null
var _lobbyPlayerList: VBoxContainer = null
var _lobbyFriendList: VBoxContainer = null
var _lobbyUseSteam: bool = true
## Steam vs IP hosting mode — set before world picker opens.
var pendingHostUseSteam: bool = true

# Shared
var playerList: VBoxContainer = null


func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    # When vanilla Settings pauses the tree, our _process/_input must still run
    # so F11 can toggle + auto-close/open-swap stays responsive.
    process_mode = Node.PROCESS_MODE_ALWAYS
    _apply_theme()
    build_ui()
    panel.hide()


func _apply_theme() -> void:
    var font: FontFile = load("res://Fonts/Lora-Regular.ttf") as FontFile
    if font == null:
        return
    var t: Theme = Theme.new()
    t.default_font = font
    t.default_font_size = 14
    theme = t


## F11 toggles the in-game coop panel. Gameplay-only to avoid clashing with menu UI.
## While coop panel is open, Esc/Tab are swallowed so Settings/Inventory can't
## open on top — same-key rule: each menu is closed by its own opener.
func _input(event: InputEvent) -> void:
    if !is_in_gameplay():
        return

    # Block Settings (Esc) and Interface (Tab) actions while coop panel is open.
    if panelVisible && (event.is_action_pressed("settings") || event.is_action_pressed("interface")):
        get_viewport().set_input_as_handled()
        return

    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if event.keycode == KEY_F11:
        # Same-key toggle rule: F11 only acts on coop panel. If another menu
        # (Settings/Inventory) is open, F11 is ignored — user must press its
        # own key to close it first, matching vanilla's menu exclusion.
        if !panelVisible && (CoopManager.gd.settings || CoopManager.gd.interface):
            get_viewport().set_input_as_handled()
            return
        toggle_panel()
        get_viewport().set_input_as_handled()


func toggle_panel() -> void:
    if panelVisible:
        close_panel()
    else:
        open_panel()


func open_panel() -> void:
    if panelVisible:
        return
    panelVisible = true
    panel.visible = true
    _dimBackground.visible = true
    _pausedLabel.visible = true
    # Confine matches vanilla Settings (UIManager.UIOpen) — cursor stays inside window.
    Input.set_mouse_mode(Input.MOUSE_MODE_CONFINED)
    # Freeze player input only — we DON'T pause the tree in coop because that
    # would halt host-side network state / RPC dispatch and desync all peers.
    CoopManager.gd.freeze = true


func build_ui() -> void:
    # Full-screen dim behind panel, matches vanilla Settings overlay.
    _dimBackground = ColorRect.new()
    _dimBackground.name = "DimBackground"
    _dimBackground.color = Color(0, 0, 0, 0.75)
    _dimBackground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _dimBackground.mouse_filter = Control.MOUSE_FILTER_STOP
    _dimBackground.visible = false
    add_child(_dimBackground)

    # "Game Paused" banner at top-center.
    _pausedLabel = Label.new()
    _pausedLabel.name = "PausedLabel"
    _pausedLabel.text = "Game Paused"
    _pausedLabel.add_theme_font_size_override("font_size", 16)
    _pausedLabel.add_theme_color_override("font_color", Color(0.85, 0.25, 0.25, 1.0))
    _pausedLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _pausedLabel.anchor_left = 0.0
    _pausedLabel.anchor_right = 1.0
    _pausedLabel.anchor_top = 0.0
    _pausedLabel.anchor_bottom = 0.0
    _pausedLabel.offset_top = 120
    _pausedLabel.offset_bottom = 144
    _pausedLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _pausedLabel.visible = false
    add_child(_pausedLabel)

    panel = PanelContainer.new()
    panel.name = "CoopPanel"
    panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
    panel.grow_vertical = Control.GROW_DIRECTION_BOTH
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    # Kill vanilla PanelContainer grey bg; dim ColorRect behind already darkens scene.
    panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
    add_child(panel)

    var margin: MarginContainer = MarginContainer.new()
    margin.name = "Margin"
    margin.add_theme_constant_override("margin_left", 24)
    margin.add_theme_constant_override("margin_right", 24)
    margin.add_theme_constant_override("margin_top", 20)
    margin.add_theme_constant_override("margin_bottom", 20)
    panel.add_child(margin)

    var columns: HBoxContainer = HBoxContainer.new()
    columns.name = "Columns"
    columns.add_theme_constant_override("separation", 48)
    margin.add_child(columns)

    var mainCol: VBoxContainer = VBoxContainer.new()
    mainCol.name = "MainCol"
    mainCol.custom_minimum_size = Vector2(500, 0)
    mainCol.add_theme_constant_override("separation", 8)
    columns.add_child(mainCol)

    # Top row: [ title/subtitle/status (left) ] [ Connected Players (right) ]
    var topRow: HBoxContainer = HBoxContainer.new()
    topRow.name = "TopRow"
    topRow.add_theme_constant_override("separation", 24)
    mainCol.add_child(topRow)

    var titleBlock: VBoxContainer = VBoxContainer.new()
    titleBlock.name = "TitleBlock"
    titleBlock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    topRow.add_child(titleBlock)

    var titleLabel: Label = Label.new()
    titleLabel.name = "TitleLabel"
    titleLabel.text = "Multiplayer"
    titleLabel.add_theme_font_size_override("font_size", 22)
    titleBlock.add_child(titleLabel)

    _subtitleLabel = Label.new()
    _subtitleLabel.name = "SubtitleLabel"
    _subtitleLabel.text = "Co-op session"
    _subtitleLabel.add_theme_font_size_override("font_size", 12)
    titleBlock.add_child(_subtitleLabel)

    statusLabel = Label.new()
    statusLabel.name = "StatusLabel"
    statusLabel.text = "Disconnected"
    statusLabel.add_theme_font_size_override("font_size", 14)
    titleBlock.add_child(statusLabel)

    # Players column sits on the right of the title info (in TopRow).
    var playersBlock: VBoxContainer = VBoxContainer.new()
    playersBlock.name = "PlayersBlock"
    playersBlock.custom_minimum_size = Vector2(200, 0)
    topRow.add_child(playersBlock)

    var playersHeader: Label = Label.new()
    playersHeader.name = "ConnectedPlayersLabel"
    playersHeader.text = "Connected Players"
    playersHeader.add_theme_font_size_override("font_size", 14)
    playersBlock.add_child(playersHeader)

    playerList = VBoxContainer.new()
    playerList.name = "PlayerList"
    playersBlock.add_child(playerList)

    # Session info + controls row (visible only during session):
    #   [ mode+address (left) ] [ Disconnect/Logs stacked (right) ]
    _sessionInfoRow = HBoxContainer.new()
    _sessionInfoRow.name = "SessionInfoRow"
    _sessionInfoRow.add_theme_constant_override("separation", 12)
    _sessionInfoRow.visible = false
    mainCol.add_child(_sessionInfoRow)

    var infoCol: VBoxContainer = VBoxContainer.new()
    infoCol.name = "InfoCol"
    infoCol.add_theme_constant_override("separation", 4)
    infoCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _sessionInfoRow.add_child(infoCol)

    _modeLabel = Label.new()
    _modeLabel.name = "ModeLabel"
    _modeLabel.add_theme_font_size_override("font_size", 12)
    infoCol.add_child(_modeLabel)

    _addressRow = HBoxContainer.new()
    _addressRow.name = "AddressRow"
    _addressRow.add_theme_constant_override("separation", 6)
    infoCol.add_child(_addressRow)

    var addrPrefix: Label = Label.new()
    addrPrefix.name = "AddrPrefixLabel"
    addrPrefix.text = "Address:"
    addrPrefix.add_theme_font_size_override("font_size", 12)
    _addressRow.add_child(addrPrefix)

    _addressLabel = Label.new()
    _addressLabel.name = "AddressLabel"
    _addressLabel.add_theme_font_size_override("font_size", 12)
    _addressRow.add_child(_addressLabel)

    var addrCopyBtn: Button = Button.new()
    addrCopyBtn.name = "CopyAddressBtn"
    addrCopyBtn.text = "Copy"
    addrCopyBtn.custom_minimum_size = Vector2(60, 22)
    addrCopyBtn.pressed.connect(_on_address_copy_pressed)
    _addressRow.add_child(addrCopyBtn)


    mainCol.add_child(_make_spacer(6))

    # Display name row (above host controls; used on Direct IP where Steam name unavailable)
    _nameRow = HBoxContainer.new()
    _nameRow.name = "NameRow"
    _nameRow.add_theme_constant_override("separation", 8)
    mainCol.add_child(_nameRow)

    var nameLabel: Label = Label.new()
    nameLabel.name = "NameLabel"
    nameLabel.text = "Name"
    nameLabel.custom_minimum_size = Vector2(60, 0)
    _nameRow.add_child(nameLabel)

    _nameInput = LineEdit.new()
    _nameInput.name = "NameInput"
    _nameInput.placeholder_text = "Player_%d" % CoopManager.localPeerId
    _nameInput.text = CoopManager.coopCustomName
    _nameInput.max_length = 32
    _nameInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _nameInput.custom_minimum_size = Vector2(0, 28)
    _nameInput.mouse_filter = Control.MOUSE_FILTER_STOP
    _nameInput.text_submitted.connect(_on_name_submitted)
    _nameInput.focus_exited.connect(_on_name_focus_exited)
    _nameRow.add_child(_nameInput)

    # Host row: Host (Steam) | Host (IP)
    _hostRow = HBoxContainer.new()
    _hostRow.name = "HostRow"
    _hostRow.add_theme_constant_override("separation", 8)
    mainCol.add_child(_hostRow)

    var hostSteamBtn: Button = Button.new()
    hostSteamBtn.name = "HostSteamBtn"
    hostSteamBtn.text = "Host (Steam)"
    hostSteamBtn.custom_minimum_size = Vector2(0, 36)
    hostSteamBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hostSteamBtn.pressed.connect(on_host_pressed)
    _hostRow.add_child(hostSteamBtn)

    var hostIPBtn: Button = Button.new()
    hostIPBtn.name = "HostIPBtn"
    hostIPBtn.text = "Host (IP)"
    hostIPBtn.custom_minimum_size = Vector2(0, 36)
    hostIPBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hostIPBtn.pressed.connect(_on_host_ip_pressed)
    _hostRow.add_child(hostIPBtn)

    # IP/Port/Join row
    _ipJoinRow = HBoxContainer.new()
    _ipJoinRow.name = "IPJoinRow"
    _ipJoinRow.add_theme_constant_override("separation", 8)
    mainCol.add_child(_ipJoinRow)

    _inlineAddrInput = LineEdit.new()
    _inlineAddrInput.name = "JoinAddrInput"
    _inlineAddrInput.placeholder_text = "127.0.0.1"
    _inlineAddrInput.text = "127.0.0.1"
    _inlineAddrInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _inlineAddrInput.custom_minimum_size = Vector2(0, 32)
    _inlineAddrInput.mouse_filter = Control.MOUSE_FILTER_STOP
    _ipJoinRow.add_child(_inlineAddrInput)

    _inlinePortInput = LineEdit.new()
    _inlinePortInput.name = "JoinPortInput"
    _inlinePortInput.placeholder_text = "9050"
    _inlinePortInput.text = str(CoopManager.DEFAULT_PORT)
    _inlinePortInput.custom_minimum_size = Vector2(80, 32)
    _inlinePortInput.mouse_filter = Control.MOUSE_FILTER_STOP
    _ipJoinRow.add_child(_inlinePortInput)

    var joinBtn: Button = Button.new()
    joinBtn.name = "JoinBtn"
    joinBtn.text = "Join"
    joinBtn.custom_minimum_size = Vector2(80, 32)
    joinBtn.pressed.connect(_on_inline_join_pressed)
    _ipJoinRow.add_child(joinBtn)

    mainCol.add_child(_make_spacer(8))

    # Bottom session controls: Disconnect + Logs stacked vertically.
    _bottomControlsCol = VBoxContainer.new()
    _bottomControlsCol.name = "BottomControlsCol"
    _bottomControlsCol.add_theme_constant_override("separation", 6)
    _bottomControlsCol.visible = false
    mainCol.add_child(_bottomControlsCol)

    var sessDisconnectBtn: Button = Button.new()
    sessDisconnectBtn.name = "DisconnectBtn"
    sessDisconnectBtn.text = "Disconnect"
    sessDisconnectBtn.custom_minimum_size = Vector2(0, 32)
    sessDisconnectBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sessDisconnectBtn.pressed.connect(on_disconnect_pressed)
    _bottomControlsCol.add_child(sessDisconnectBtn)

    var sessLogsBtn: Button = Button.new()
    sessLogsBtn.name = "LogsBtn"
    sessLogsBtn.text = "Logs"
    sessLogsBtn.custom_minimum_size = Vector2(0, 32)
    sessLogsBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sessLogsBtn.pressed.connect(_on_collect_logs_pressed)
    _bottomControlsCol.add_child(sessLogsBtn)

    # Right column — Invite Friends (Steam only)
    _friendsCol = VBoxContainer.new()
    _friendsCol.name = "FriendsCol"
    _friendsCol.custom_minimum_size = Vector2(280, 0)
    columns.add_child(_friendsCol)

    var friendsHeader: Label = Label.new()
    friendsHeader.name = "FriendsHeaderLabel"
    friendsHeader.text = "Invite Friends"
    friendsHeader.add_theme_font_size_override("font_size", 16)
    _friendsCol.add_child(friendsHeader)

    _friendsCol.add_child(_make_spacer(4))

    inviteBtn = Button.new()
    inviteBtn.name = "RefreshFriendsBtn"
    inviteBtn.text = "Refresh"
    inviteBtn.pressed.connect(on_invite_pressed)
    _friendsCol.add_child(inviteBtn)

    friendScroll = ScrollContainer.new()
    friendScroll.name = "FriendsScroll"
    friendScroll.custom_minimum_size = Vector2(0, 360)
    friendScroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    friendScroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _friendsCol.add_child(friendScroll)

    friendList = VBoxContainer.new()
    friendList.name = "FriendsList"
    friendList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    friendScroll.add_child(friendList)


func _make_spacer(height: int) -> Control:
    var s: Control = Control.new()
    s.name = "Spacer"
    s.custom_minimum_size = Vector2(0, height)
    return s


func _on_host_ip_pressed() -> void:
    if CoopManager.is_session_active():
        return
    pendingHostUseSteam = false
    show_world_picker()


func _on_inline_join_pressed() -> void:
    if CoopManager.is_session_active():
        return
    var addr: String = _inlineAddrInput.text.strip_edges() if _inlineAddrInput != null else ""
    if addr.is_empty():
        addr = "127.0.0.1"
    var port: int = CoopManager.DEFAULT_PORT
    if _inlinePortInput != null && !_inlinePortInput.text.strip_edges().is_empty():
        port = int(_inlinePortInput.text.strip_edges())
    CoopManager.join_game(addr, port, true)


func _on_name_submitted(newText: String) -> void:
    CoopManager.set_custom_name(newText)


func _on_name_focus_exited() -> void:
    if _nameInput != null:
        CoopManager.set_custom_name(_nameInput.text)


func _on_address_copy_pressed() -> void:
    if _addressLabel != null:
        DisplayServer.clipboard_set(_addressLabel.text)


func _process(_delta: float) -> void:
    if !panelVisible || CoopManager == null:
        return
    var currentState: int = 0
    var currentPeerCount: int = 0
    if CoopManager.isActive:
        # Remote peer count excludes our own slot in peerGodotIds.
        currentPeerCount = maxi(0, CoopManager.active_peer_count() - 1)
        currentState = 1 if CoopManager.isHost else 2

    if currentState == lastConnectionState && currentPeerCount == lastPeerCount:
        return
    lastConnectionState = currentState
    lastPeerCount = currentPeerCount

    var inSession: bool = currentState != 0
    _hostRow.visible = !inSession
    _ipJoinRow.visible = !inSession
    _nameRow.visible = !inSession
    _sessionInfoRow.visible = inSession
    _bottomControlsCol.visible = inSession
    var usingSteam: bool = CoopManager.currentLobbyID != "" if CoopManager.isHost else CoopManager.steamBridge != null && CoopManager.steamBridge.is_ready()
    _friendsCol.visible = !inSession || usingSteam
    # Let panel auto-size to content and re-center every state change.
    panel.reset_size()
    panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)

    match currentState:
        0:
            statusLabel.text = "Disconnected"
            _subtitleLabel.text = "Co-op session"
            _addressRow.visible = false
        1:
            var hostPeers: String = "%d peer(s)" % currentPeerCount
            statusLabel.text = "Host — %s" % hostPeers
            var mode: String = "Steam lobby" if CoopManager.currentLobbyID != "" else "Direct IP"
            _modeLabel.text = "Mode: %s" % mode
            var addrs: PackedStringArray = CoopManager.get_sharable_addresses()
            if addrs.size() > 0:
                _addressLabel.text = addrs[0]
                _addressRow.visible = true
            else:
                _addressRow.visible = false
            var worldLabel: String = _get_active_world_name()
            _subtitleLabel.text = worldLabel if !worldLabel.is_empty() else "Co-op session"
        2:
            statusLabel.text = "Connected"
            _modeLabel.text = "Mode: Client"
            _addressRow.visible = false
            var worldLabel: String = _get_active_world_name()
            _subtitleLabel.text = worldLabel if !worldLabel.is_empty() else "Co-op session"

    update_player_list()
    _update_lobby_players()


func update_player_list() -> void:
    var idx: int = 0

    if CoopManager.isActive:
        var localRow: HBoxContainer = get_pooled_player_row(idx)
        idx += 1
        var localAvatar: TextureRect = localRow.get_child(0)
        var localLabel: Label = localRow.get_child(1)
        var localSuffix: String = " — Host" if CoopManager.isHost else ""
        localLabel.text = "%s (You)%s" % [CoopManager.get_local_name(), localSuffix]
        var localTex: ImageTexture = null
        if CoopManager.avatarCache.has(CoopManager.steamBridge.localSteamID):
            localTex = CoopManager.avatarCache[CoopManager.steamBridge.localSteamID]
        if localTex != null:
            localAvatar.texture = localTex
            localAvatar.show()
        else:
            localAvatar.hide()

        var localPid: int = CoopManager.localPeerId
        for peerId: int in CoopManager.peerGodotIds:
            if peerId == -1 || peerId == localPid:
                continue
            var row: HBoxContainer = get_pooled_player_row(idx)
            idx += 1
            var avatar: TextureRect = row.get_child(0)
            var label: Label = row.get_child(1)
            label.text = CoopManager.get_peer_name(peerId)
            var tex: ImageTexture = CoopManager.get_peer_avatar(peerId)
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
    row.name = "PlayerRow"
    var avatar: TextureRect = TextureRect.new()
    avatar.name = "Avatar"
    avatar.custom_minimum_size = Vector2(24, 24)
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    row.add_child(avatar)

    var label: Label = Label.new()
    label.name = "NameLabel"
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(label)

    playerList.add_child(row)
    playerLabelPool.append(row)
    return row



## Returns true if the current scene is a gameplay map (has Core/Controller).
func close_panel() -> void:
    if !panelVisible:
        return
    panelVisible = false
    panel.visible = false
    _dimBackground.visible = false
    _pausedLabel.visible = false
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    CoopManager.gd.freeze = false


func is_in_gameplay() -> bool:
    var scene: Node = get_tree().current_scene
    return is_instance_valid(scene) && scene.get_node_or_null(PATH_CONTROLLER) != null



func on_host_pressed() -> void:
    if CoopManager.is_session_active():
        return
    pendingHostUseSteam = true
    show_world_picker()



func on_disconnect_pressed() -> void:
    CoopManager.disconnect_session()


func _on_collect_logs_pressed() -> void:
    if !is_instance_valid(CoopManager):
        return
    CoopManager.logCollector.collect()


## Shows a themed, menu-specific lobby browser (separate from the F10 in-game
## panel which has cluttered controls). Called when the user clicks
func show_lobby_browser() -> void:
    _free_dialog(menuLobbyBrowser)
    menuLobbyBrowser = _make_menu_dialog_panel("Browse Lobbies", "Join a friend's game")
    add_child(menuLobbyBrowser)
    _wire_return_button(menuLobbyBrowser, hide_lobby_browser)

    var vbox: VBoxContainer = _dialog_vbox(menuLobbyBrowser)

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
    if !CoopManager.steamBridge.is_ready():
        return
    CoopManager.steamBridge.list_lobbies(on_lobby_list_received)


func on_lobby_list_received(response: Dictionary) -> void:
    # Active list & pool: menu browser takes priority when visible, else F10 panel.
    var activePool: Array[Button] = menuLobbyLabelPool if menuLobbyBrowser != null else lobbyLabelPool

    for i: int in range(activePool.size()):
        activePool[i].hide()

    if !response.get(&"ok", false):
        return

    var lobbies: Array = response.get(&"data", []) as Array
    for i: int in range(lobbies.size()):
        var lobby: Dictionary = lobbies[i]
        var btn: Button = get_pooled_lobby_button(i)
        var hostName: String = lobby.get(&"host_name", "Unknown")
        var players: int = lobby.get(&"players", 0)
        var maxPlayers: int = lobby.get(&"max_players", 0)
        var mapName: String = lobby.get(&"map", "")
        if mapName.is_empty():
            btn.text = "%s (%d/%d)" % [hostName, players, maxPlayers]
        else:
            btn.text = "%s — %s (%d/%d)" % [hostName, mapName, players, maxPlayers]
        var lobbyID: String = lobby.get(&"lobby_id", "")
        for conn: Dictionary in btn.pressed.get_connections():
            btn.pressed.disconnect(conn["callable"])
        btn.pressed.connect(on_lobby_join_pressed.bind(lobbyID))

    for i: int in range(lobbies.size(), activePool.size()):
        activePool[i].hide()


func on_lobby_join_pressed(lobbyID: String) -> void:
    CoopManager.steamBridge.join_lobby(lobbyID, on_lobby_joined)


func on_lobby_joined(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", { }) as Dictionary
    var hostSteamID: String = data.get(&"host_steam_id", "")
    var lobbyID: String = data.get(&"lobby_id", "")
    if hostSteamID.is_empty():
        CoopManager._log("Lobby has no host Steam ID")
        return
    # Steam invite_poll can fire JoinRequested multiple times for the same lobby —
    # gate so we only start one P2P tunnel per accepted invite.
    if CoopManager.currentLobbyID == lobbyID && CoopManager.isActive:
        CoopManager._log("Lobby join callback re-fired for %s — already connected, ignoring" % lobbyID)
        return
    CoopManager.currentLobbyID = lobbyID
    CoopManager._log("Lobby joined — starting P2P tunnel to host %s" % hostSteamID)
    # Lobby joined successfully — close the browser so it doesn't sit on top of
    # the character picker and (later) the in-game scene.
    if menuLobbyBrowser != null:
        hide_lobby_browser()
    if !lobbyID.is_empty():
        CoopManager.steamBridge.get_lobby_data(lobbyID, "state", _on_host_state_received)
    CoopManager.steamBridge.start_p2p_client(hostSteamID, CoopManager.on_p2p_tunnel_ready)


func _on_host_state_received(response: Dictionary) -> void:
    if !response.get(&"ok", false):
        return
    var data: Dictionary = response.get(&"data", {}) as Dictionary
    var hostState: String = data.get(&"value", "")
    CoopManager._log("Host lobby state: %s" % hostState)
    if hostState == "in_game":
        CoopManager.pendingAutoJoin = true


func on_invite_pressed() -> void:
    if !CoopManager.steamBridge.is_ready():
        return
    if !CoopManager.isActive:
        return
    friendsVisible = !friendsVisible
    friendScroll.visible = friendsVisible
    if friendsVisible:
        CoopManager.steamBridge.get_friends(on_friends_received)


func on_friends_received(response: Dictionary) -> void:
    for i: int in range(friendLabelPool.size()):
        friendLabelPool[i].hide()

    if !response.get(&"ok", false):
        return

    var friends: Array = response.get(&"data", []) as Array
    for i: int in range(friends.size()):
        _populate_friend_row(friends[i], i)

    for i: int in range(friends.size(), friendLabelPool.size()):
        friendLabelPool[i].hide()


func _populate_friend_row(friend: Dictionary, rowIndex: int) -> void:
    var row: HBoxContainer = get_pooled_friend_row(rowIndex)
    var avatar: TextureRect = row.get_child(0)
    var nameLabel: Label = row.get_child(1)
    var btn: Button = row.get_child(2)
    var friendName: String = friend.get(&"name", "Unknown")
    var state: int = friend.get(&"state", 0)
    var inGame: bool = !String(friend.get(&"game_id", "")).is_empty()

    var styling: Dictionary = _friend_display_styling(inGame, state)
    nameLabel.text = "%s%s" % [friendName, styling.text]
    nameLabel.add_theme_color_override("font_color", styling.color)

    var steamID: String = friend.get(&"steam_id", "")
    _apply_friend_avatar(avatar, steamID)
    _rebind_friend_invite(btn, steamID, friendName)


## Returns {text, color} for the friend's display suffix based on in-game/online state.
func _friend_display_styling(inGame: bool, state: int) -> Dictionary:
    if inGame:
        return {"text": " (In-Game)", "color": Color("#90ba3c")}
    match state:
        1:
            return {"text": "", "color": Color("#57cbde")}
        2:
            return {"text": " (Busy)", "color": Color("#57cbde", 0.5)}
        3:
            return {"text": " (Away)", "color": Color("#57cbde", 0.5)}
        4:
            return {"text": " (Snooze)", "color": Color("#57cbde", 0.4)}
        _:
            return {"text": "", "color": Color("#57cbde")}


## Fetches the Steam avatar via binary channel (faster than inline base64).
## Reveals a cached texture when available, otherwise requests a fetch and hides
func _apply_friend_avatar(avatar: TextureRect, steamID: String) -> void:
    var cached: Texture2D = null
    if CoopManager.avatarCache.has(steamID):
        cached = CoopManager.avatarCache[steamID]
    if cached != null:
        avatar.texture = cached
        avatar.show()
        return
    if !steamID.is_empty():
        CoopManager.fetch_avatar(steamID)
    avatar.texture = null
    avatar.hide()


## Disconnects prior handlers before rebinding so the invite button stays idempotent
func _rebind_friend_invite(btn: Button, steamID: String, friendName: String) -> void:
    for conn: Dictionary in btn.pressed.get_connections():
        btn.pressed.disconnect(conn["callable"])
    btn.pressed.connect(on_invite_friend_pressed.bind(steamID, friendName))


func on_invite_friend_pressed(steamID: String, friendName: String) -> void:
    CoopManager.steamBridge.invite_friend(steamID, on_invite_sent.bind(friendName))


func on_invite_sent(response: Dictionary, friendName: String) -> void:
    if response.get(&"ok", false):
        CoopManager._log("Invite sent to %s" % friendName)
    else:
        CoopManager._log("Invite failed: %s" % response.get(&"error", "unknown"))


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




## Reads the display name for the currently active co-op world from meta.cfg.
func _get_active_world_name() -> String:
    if CoopManager == null || CoopManager.worldId.is_empty():
        return ""
    var cfgPath: String = COOP_DIR + CoopManager.worldId + "/" + META_FILE
    if !FileAccess.file_exists(cfgPath):
        return CoopManager.worldId
    var cfg: ConfigFile = ConfigFile.new()
    if cfg.load(cfgPath) != OK:
        return CoopManager.worldId
    return cfg.get_value("world", "name", CoopManager.worldId)


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

    var vbox: VBoxContainer = _dialog_vbox(worldPickerPanel)

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


## Full-screen menu scaffold matching the game's Modes/Difficulty layout:
## everything (header, subheader, content, return) stacks tightly in a single
func _make_menu_dialog_panel(titleText: String, subtitleText: String) -> Control:
    var gameTheme: Theme = load("res://UI/Themes/Theme.tres")

    var wrapper: Control = Control.new()
    wrapper.name = "MenuDialog"
    wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    # PASS, not STOP — wrapper spans full rect but has no _gui_input handler.
    # STOP swallows every mouse motion event, which blocks the in-game camera
    # if the wrapper lingers after a scene change. The inner centered panel
    # still uses MOUSE_FILTER_STOP so clicks on the dialog itself register.
    wrapper.mouse_filter = Control.MOUSE_FILTER_PASS
    if gameTheme != null:
        wrapper.theme = gameTheme

    # Single centered column — everything stacks together (no large screen-edge anchors).
    var outer: VBoxContainer = VBoxContainer.new()
    outer.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    outer.grow_horizontal = Control.GROW_DIRECTION_BOTH
    outer.grow_vertical = Control.GROW_DIRECTION_BOTH
    outer.custom_minimum_size = Vector2(560, 0)
    outer.add_theme_constant_override("separation", 4)
    wrapper.add_child(outer)

    var header: Label = Label.new()
    header.name = "Header"
    header.text = titleText
    header.add_theme_font_size_override("font_size", 20)
    header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(header)

    if !subtitleText.is_empty():
        var subheader: Label = Label.new()
        subheader.name = "Subheader"
        subheader.text = subtitleText
        subheader.modulate = Color(1, 1, 1, 0.5)
        subheader.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        subheader.add_theme_font_size_override("font_size", 12)
        outer.add_child(subheader)

    var topSpacer: Control = Control.new()
    topSpacer.custom_minimum_size = Vector2(0, 16)
    outer.add_child(topSpacer)

    # Content slot — callers append world/lobby lists, action buttons, etc.
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.name = "VBox"
    vbox.add_theme_constant_override("separation", 8)
    outer.add_child(vbox)

    var bottomSpacer: Control = Control.new()
    bottomSpacer.custom_minimum_size = Vector2(0, 16)
    outer.add_child(bottomSpacer)

    var returnBtn: Button = Button.new()
    returnBtn.name = "ReturnBtn"
    returnBtn.text = "← Return"
    returnBtn.custom_minimum_size = Vector2(256, 40)
    returnBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    returnBtn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    outer.add_child(returnBtn)

    return wrapper


## Wires the Return button on a menu dialog to the given callback.
func _wire_return_button(dialog: Control, callback: Callable) -> void:
    var returnBtn: Button = dialog.find_child("ReturnBtn", true, false) as Button
    if returnBtn == null:
        return
    for conn: Dictionary in returnBtn.pressed.get_connections():
        returnBtn.pressed.disconnect(conn["callable"])
    returnBtn.pressed.connect(callback)


## Returns the content VBox slot inside a menu dialog (where callers append
## buttons/lists). Uses find_child so callers don't need to know the panel's
func _dialog_vbox(dialog: Control) -> VBoxContainer:
    return dialog.find_child("VBox", true, false) as VBoxContainer


## Hides the world picker. Returns to the Multiplayer submenu when opened from
func hide_world_picker() -> void:
    _free_dialog(worldPickerPanel)
    worldPickerPanel = null
    worldPickerVisible = false
    _show_mp_submenu_if_on_menu()


func _free_dialog(dialog: Control) -> void:
    if dialog == null:
        return
    var wrapper: Node = dialog.get_meta(&"wrapper") if dialog.has_meta(&"wrapper") else null
    if wrapper != null && is_instance_valid(wrapper):
        wrapper.queue_free()
    else:
        dialog.queue_free()


## Frees every outstanding menu dialog wrapper. Called from
## [method CoopManager.on_scene_changed] so any dialog whose back-button
## cleanup was skipped (e.g. Host -> New World -> Play flow transitions
## straight into gameplay without closing the lobby panel) doesn't linger
func free_all_dialogs() -> void:
    for child: Node in get_children():
        if child.name == &"MenuDialog":
            child.queue_free()
    lobbyPanel = null
    worldPickerPanel = null
    newWorldPanel = null
    directJoinPanel = null
    menuLobbyBrowser = null
    worldPickerVisible = false


## Shows the CoopMPSubmenu on the main menu. Used as the "Return" target for
func _show_mp_submenu_if_on_menu() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || scene.scene_file_path != "res://Scenes/Menu.tscn":
        return
    var submenu: Node = scene.get_node_or_null(PATH_MENU_SUBMENU)
    var main: Node = scene.get_node_or_null(PATH_MENU_MAIN)
    if submenu != null:
        submenu.show()
    elif main != null:
        # Fallback if submenu is missing
        main.show()


## When a coop dialog is cancelled from the main menu, restore Main visibility
func _restore_main_menu_if_open() -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || scene.scene_file_path != "res://Scenes/Menu.tscn":
        return
    var main: Node = scene.get_node_or_null(PATH_MENU_MAIN)
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
    worlds.sort_custom(_sort_worlds_by_last_played)

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
        var dayVal: Variant = worldSave.get(&"day")
        var seasonVal: Variant = worldSave.get(&"season")
        var diffVal: Variant = worldSave.get(&"difficulty")
        meta["day"] = dayVal if dayVal != null else 1
        meta["season"] = seasonVal if seasonVal != null else 1
        meta["difficulty"] = diffVal if diffVal != null else 1

    meta["players"] = _count_players_in_world(worldDir + "players/")
    return meta


## Returns just the metadata line (day, difficulty, season, player count, last played)
func _format_world_meta(world: Dictionary) -> String:
    var day: int = world.get(&"day", 1)
    var season: int = world.get(&"season", 1)
    var diff: int = world.get(&"difficulty", 1)
    var players: int = world.get(&"players", 0)
    var lastPlayed: int = world.get(&"last_played", 0)

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
        @warning_ignore_start("integer_division")
        if elapsed < 3600:
            elapsedText = "%dm ago" % max(1, elapsed / 60)
        elif elapsed < 86400:
            elapsedText = "%dh ago" % (elapsed / 3600)
        else:
            elapsedText = "%dd ago" % (elapsed / 86400)
        @warning_ignore_restore("integer_division")
        base += " • " + elapsedText

    return base


func _format_world_label(world: Dictionary) -> String:
    var world_name: String = world.get(&"name", "Unknown")
    var day: int = world.get(&"day", 1)
    var season: int = world.get(&"season", 1)
    var diff: int = world.get(&"difficulty", 1)
    var players: int = world.get(&"players", 0)
    var lastPlayed: int = world.get(&"last_played", 0)

    var seasonText: String = "Summer" if season == 1 else "Winter"
    var diffText: String = "Normal"
    match diff:
        2: diffText = "Hard"
        3: diffText = "Permadeath"

    var timeText: String = ""
    if lastPlayed > 0:
        var now: int = int(Time.get_unix_time_from_system())
        var elapsed: int = now - lastPlayed
        @warning_ignore_start("integer_division")
        if elapsed < 3600:
            timeText = " — %dm ago" % (elapsed / 60)
        elif elapsed < 86400:
            timeText = " — %dh ago" % (elapsed / 3600)
        else:
            timeText = " — %dd ago" % (elapsed / 86400)
        @warning_ignore_restore("integer_division")

    return "%s — %s Day %d, %s, %d player(s)%s" % [world_name, seasonText, day, diffText, players, timeText]


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




func show_new_world_dialog() -> void:
    print("[coop_ui] show_new_world_dialog called")
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

    var vbox: VBoxContainer = _dialog_vbox(newWorldPanel)

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
    print("[coop_ui] on_create_world_confirmed called")
    # Steam gate only when hosting via Steam — IP mode doesn't need it.
    if pendingHostUseSteam && (!CoopManager.steamBridge.is_ready() || !CoopManager.steamBridge.ownsGame):
        CoopManager._log("[coop_ui] Create aborted — Steam not ready, try again in a moment")
        return

    var worldName: String = newWorldNameInput.text.strip_edges()
    if worldName.is_empty():
        worldName = "World"

    var worldId: String = "world_%d" % Time.get_unix_time_from_system()

    var worldDir: String = COOP_DIR + worldId + "/"
    DirAccess.make_dir_recursive_absolute(worldDir)
    _write_world_meta(worldDir, worldName)

    _free_dialog(newWorldPanel)
    newWorldPanel = null

    CoopManager.saveMirror.set_active_world(worldId)
    # IP path: server already running from show_host_ip_dialog, just finalize.
    # Steam path: start server + finalize in one call.
    if CoopManager.is_session_active():
        CoopManager.finalize_host()
    else:
        CoopManager.host_game(CoopManager.DEFAULT_PORT, pendingHostUseSteam)
        if !CoopManager.is_session_active() || !CoopManager.isHost:
            CoopManager._log("[coop_ui] host_game failed — cleaning up world dir %s" % worldDir)
            _remove_dir_recursive(worldDir)
            CoopManager.saveMirror.clear_active_world()
            return

    # Save paths are up now, so the picker can write appearance.json. Defer
    # NewGame + mirror + LoadScene until the host confirms a character — we
    # don't want to write World.tres / Character.tres for a world they might
    # back out of during the picker.
    show_character_picker(
        _on_host_picker_confirm,
        _on_host_picker_cancel.bind(worldId, worldDir),
    )


## Spawns the character-creation dialog. [param onConfirm] runs after confirm,
func show_character_picker(onConfirm: Callable, onCancel: Callable) -> void:
    var picker: Control = load("res://mod/ui/character_creation.gd").new()
    add_child(picker)
    picker.init(onConfirm, onCancel)


func _on_host_picker_confirm(_entry: Dictionary = {}) -> void:
    var loader: Node = get_node_or_null(PATH_LOADER_ABS)
    if loader == null:
        return
    CoopManager.saveMirror.wipe_user_saves()
    loader.NewGame(newWorldDifficulty, newWorldSeason)
    CoopManager.saveMirror.mirror_user_to_world()
    loader.LoadScene("Cabin")


## Back out of world creation from inside the picker: tear down the host
## session we started pre-picker, delete the empty world dir, and return to
func _on_host_picker_cancel(worldId: String, worldDir: String) -> void:
    CoopManager.disconnect_session()
    CoopManager.saveMirror.clear_active_world()
    _remove_dir_recursive(worldDir)
    CoopManager._log("[coop_ui] world creation cancelled in picker (%s)" % worldId)
    show_world_picker()


## Recursively removes a directory and its contents. Used to clean up an empty
func _remove_dir_recursive(path: String) -> void:
    if !DirAccess.dir_exists_absolute(path):
        return
    var dir: DirAccess = DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        var full: String = path + entry
        if dir.current_is_dir():
            _remove_dir_recursive(full + "/")
        else:
            DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
        entry = dir.get_next()
    dir.list_dir_end()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func on_new_world_back() -> void:
    _free_dialog(newWorldPanel)
    newWorldPanel = null
    show_world_picker()




func show_direct_join_dialog() -> void:
    directJoinPanel = _make_menu_dialog_panel("Direct Join", "Connect to a host by IP")
    add_child(directJoinPanel)
    _wire_return_button(directJoinPanel, _on_direct_join_back)

    var vbox: VBoxContainer = _dialog_vbox(directJoinPanel)

    var addrLabel: Label = Label.new()
    addrLabel.text = "IP Address"
    addrLabel.add_theme_font_size_override("font_size", 14)
    vbox.add_child(addrLabel)

    djAddressInput = LineEdit.new()
    djAddressInput.placeholder_text = "127.0.0.1"
    djAddressInput.mouse_filter = Control.MOUSE_FILTER_STOP
    djAddressInput.custom_minimum_size = Vector2(0, 32)
    vbox.add_child(djAddressInput)

    var portLabel: Label = Label.new()
    portLabel.text = "Port"
    portLabel.add_theme_font_size_override("font_size", 14)
    vbox.add_child(portLabel)

    djPortInput = LineEdit.new()
    djPortInput.placeholder_text = str(CoopManager.DEFAULT_PORT)
    djPortInput.mouse_filter = Control.MOUSE_FILTER_STOP
    djPortInput.custom_minimum_size = Vector2(0, 32)
    vbox.add_child(djPortInput)

    var spacer: Control = Control.new()
    spacer.custom_minimum_size = Vector2(0, 8)
    vbox.add_child(spacer)

    var connectBtn: Button = Button.new()
    connectBtn.text = "Connect"
    connectBtn.custom_minimum_size = Vector2(256, 40)
    connectBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    connectBtn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    connectBtn.pressed.connect(_on_direct_join_connect)
    vbox.add_child(connectBtn)


func _on_direct_join_connect() -> void:
    var addr: String = djAddressInput.text.strip_edges() if djAddressInput != null else ""
    if addr.is_empty():
        addr = "127.0.0.1"
    var port: int = CoopManager.DEFAULT_PORT
    if djPortInput != null && !djPortInput.text.strip_edges().is_empty():
        port = int(djPortInput.text.strip_edges())
    _free_dialog(directJoinPanel)
    directJoinPanel = null
    # Re-surface MP submenu so the player isn't left on a blank screen while
    # ENet handshakes; a scene change will kill it on successful connect, and
    # on failure it lets them retry without restarting the client.
    _show_mp_submenu_if_on_menu()
    CoopManager.join_game(addr, port, true)


func _on_direct_join_back() -> void:
    _free_dialog(directJoinPanel)
    directJoinPanel = null
    _show_mp_submenu_if_on_menu()




## Unified lobby for both Steam and IP hosting. Starts the ENet server
func show_lobby(useSteam: bool) -> void:
    _lobbyUseSteam = useSteam
    pendingHostUseSteam = useSteam
    var port: int = CoopManager.DEFAULT_PORT

    if !CoopManager.is_session_active():
        if !CoopManager.start_hosting(port, useSteam):
            return

    var steamName: String = CoopManager.steamBridge.localSteamName if CoopManager.steamBridge.is_ready() else ""
    var subtitle: String = ("Steam: %s" % steamName if !steamName.is_empty() else "Steam lobby") if useSteam else "Direct connect"
    lobbyPanel = _make_menu_dialog_panel("Lobby", subtitle)
    add_child(lobbyPanel)
    _wire_return_button(lobbyPanel, _on_lobby_back)

    var vbox: VBoxContainer = _dialog_vbox(lobbyPanel)

    # IP addresses (IP mode only)
    if !useSteam:
        var addrBox: HBoxContainer = HBoxContainer.new()
        addrBox.add_theme_constant_override("separation", 8)
        addrBox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
        vbox.add_child(addrBox)

        for addr: String in CoopManager.get_sharable_addresses():
            var text: String = "%s:%d" % [addr, port]
            var label: Label = Label.new()
            label.text = text
            addrBox.add_child(label)

            var copyBtn: Button = Button.new()
            copyBtn.text = "Copy"
            copyBtn.mouse_filter = Control.MOUSE_FILTER_STOP
            copyBtn.set_meta(&"copyText", text)
            copyBtn.pressed.connect(_on_lobby_copy_text.bind(text))
            addrBox.add_child(copyBtn)

    # Session settings (host-only). Daylight/night Simulation rate multipliers
    # fall through to CoopManager.set_setting which broadcasts to all peers via
    # world_state.broadcast_settings. Sliders cover 0.1×..10× — lets the host
    # compress a full day cycle to ~3 min or slow night pacing for sneaking.
    # Gate on isHost even though show_lobby's call sites are both host entries
    # today — defensive so future non-host refactors can't re-open this path
    # and flood request_setting_change on every slider tick.
    var columns: HBoxContainer = HBoxContainer.new()
    columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vbox.add_child(columns)

    if CoopManager.isHost:
        var settingsCol: VBoxContainer = VBoxContainer.new()
        settingsCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        columns.add_child(settingsCol)

        var settingsHeader: Label = Label.new()
        settingsHeader.text = "Session Settings"
        settingsHeader.add_theme_font_size_override("font_size", 14)
        settingsCol.add_child(settingsHeader)

        var settingsScroll: ScrollContainer = ScrollContainer.new()
        settingsScroll.custom_minimum_size = Vector2(0, 280)
        settingsScroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        settingsScroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        settingsCol.add_child(settingsScroll)

        var settingsBox: VBoxContainer = VBoxContainer.new()
        settingsBox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        settingsBox.add_theme_constant_override("separation", 4)
        settingsScroll.add_child(settingsBox)

        _build_rate_slider(settingsBox, "Day rate", "day_rate_multiplier")
        _build_rate_slider(settingsBox, "Night rate", "night_rate_multiplier")
        _build_rate_slider(settingsBox, "AI spawns", "ai_spawn_multiplier", 0.0, 3.0, 0.1)
        _build_rate_slider(settingsBox, "AI aggression", "ai_aggression_multiplier", 0.1, 3.0, 0.1)
        _build_rate_slider(settingsBox, "Dmg → AI", "damage_to_ai_multiplier", 0.1, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Dmg → player", "damage_to_player_multiplier", 0.1, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Loot", "loot_multiplier", 0.0, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Stamina regen", "stamina_regen_multiplier", 0.1, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Stamina drain", "stamina_drain_multiplier", 0.1, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Temp loss", "temperature_loss_multiplier", 0.1, 5.0, 0.1)
        _build_rate_slider(settingsBox, "Vitals decay", "vitals_decay_multiplier", 0.1, 5.0, 0.1)
        _build_toggle(settingsBox, "Weather locked", "weather_locked")
        _build_toggle(settingsBox, "Friendly fire", "friendly_fire")

    # Connected players
    var playersCol: VBoxContainer = VBoxContainer.new()
    playersCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    columns.add_child(playersCol)

    var playersHeader: Label = Label.new()
    playersHeader.text = "Players"
    playersHeader.add_theme_font_size_override("font_size", 14)
    playersCol.add_child(playersHeader)

    _lobbyPlayerList = VBoxContainer.new()
    playersCol.add_child(_lobbyPlayerList)

    # Friends list (Steam mode only)
    if useSteam:
        var friendsHeader: Label = Label.new()
        friendsHeader.text = "Invite Friends"
        friendsHeader.add_theme_font_size_override("font_size", 14)
        vbox.add_child(friendsHeader)

        friendScroll = ScrollContainer.new()
        friendScroll.custom_minimum_size = Vector2(0, 150)
        friendScroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        vbox.add_child(friendScroll)

        _lobbyFriendList = VBoxContainer.new()
        _lobbyFriendList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        friendScroll.add_child(_lobbyFriendList)

        _refresh_lobby_friends()

    # Select World above Return
    var returnBtn: Button = lobbyPanel.find_child("ReturnBtn", true, false)
    var outerVBox: VBoxContainer = returnBtn.get_parent()
    var selectBtn: Button = Button.new()
    selectBtn.text = "Select World"
    selectBtn.custom_minimum_size = Vector2(256, 40)
    selectBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    selectBtn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    selectBtn.pressed.connect(_on_lobby_select_world)
    outerVBox.add_child(selectBtn)
    outerVBox.move_child(selectBtn, returnBtn.get_index())


func _on_lobby_copy_text(copyText: String) -> void:
    DisplayServer.clipboard_set(copyText)


## Builds a labeled HSlider row bound to a [member CoopManager.settings] key.
## Defaults cover simulation rate sliders (0.1×..10×). Override min/max/step
## for narrower knobs. Slider → CoopManager.set_setting broadcasts.
func _build_rate_slider(
    parent: VBoxContainer, caption: String, key: String,
    minv: float = 0.1, maxv: float = 10.0, step: float = 0.1,
) -> void:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(row)

    var label: Label = Label.new()
    label.text = caption
    label.custom_minimum_size = Vector2(110, 0)
    row.add_child(label)

    var slider: HSlider = HSlider.new()
    slider.min_value = minv
    slider.max_value = maxv
    slider.step = step
    slider.value = float(CoopManager.get_setting(key, 1.0))
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.custom_minimum_size = Vector2(120, 0)
    slider.scrollable = false
    row.add_child(slider)

    var valueLabel: Label = Label.new()
    valueLabel.text = "%.1fx" % slider.value
    valueLabel.custom_minimum_size = Vector2(48, 0)
    row.add_child(valueLabel)

    slider.value_changed.connect(_on_rate_slider_changed.bind(key, valueLabel))


func _build_toggle(parent: VBoxContainer, caption: String, key: String) -> void:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(row)

    var label: Label = Label.new()
    label.text = caption
    label.custom_minimum_size = Vector2(110, 0)
    row.add_child(label)

    var checkbox: CheckButton = CheckButton.new()
    checkbox.button_pressed = float(CoopManager.get_setting(key, 0.0)) >= 0.5
    checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(checkbox)

    checkbox.toggled.connect(_on_toggle_changed.bind(key))


func _on_rate_slider_changed(value: float, key: String, valueLabel: Label) -> void:
    if is_instance_valid(valueLabel):
        valueLabel.text = "%.1fx" % value
    if is_instance_valid(CoopManager) && CoopManager.has_method(&"set_setting"):
        CoopManager.set_setting(key, value)


func _on_toggle_changed(pressed: bool, key: String) -> void:
    if is_instance_valid(CoopManager) && CoopManager.has_method(&"set_setting"):
        CoopManager.set_setting(key, 1.0 if pressed else 0.0)


func _sort_worlds_by_last_played(a: Dictionary, b: Dictionary) -> bool:
    return a.get(&"last_played", 0) > b.get(&"last_played", 0)


func _update_lobby_players() -> void:
    if _lobbyPlayerList == null || !is_instance_valid(_lobbyPlayerList):
        return
    for child: Node in _lobbyPlayerList.get_children():
        child.queue_free()
    if !CoopManager.isActive:
        return
    var hostLabel: Label = Label.new()
    var hostName: String = CoopManager.get_peer_name(CoopManager.localPeerId)
    hostLabel.text = "%s (Host)" % hostName
    hostLabel.add_theme_font_size_override("font_size", 13)
    _lobbyPlayerList.add_child(hostLabel)
    var localPid: int = CoopManager.localPeerId
    for peerId: int in CoopManager.peerGodotIds:
        if peerId == -1 || peerId == localPid:
            continue
        var peerLabel: Label = Label.new()
        peerLabel.text = CoopManager.get_peer_name(peerId)
        peerLabel.add_theme_font_size_override("font_size", 13)
        _lobbyPlayerList.add_child(peerLabel)


func _refresh_lobby_friends() -> void:
    if !_lobbyUseSteam || !CoopManager.steamBridge.is_ready():
        return
    CoopManager.steamBridge.get_friends(on_lobby_friends_received)


func on_lobby_friends_received(response: Dictionary) -> void:
    if _lobbyFriendList == null || !is_instance_valid(_lobbyFriendList):
        return
    if !response.get(&"ok", false):
        return
    for child: Node in _lobbyFriendList.get_children():
        child.queue_free()
    var friends: Array = response.get(&"data", []) as Array
    for friend: Dictionary in friends:
        var friendName: String = friend.get(&"name", "Unknown")
        var state: int = friend.get(&"state", 0)
        if state == 0:
            continue
        var row: HBoxContainer = HBoxContainer.new()
        _lobbyFriendList.add_child(row)

        var label: Label = Label.new()
        label.text = friendName
        label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        label.add_theme_font_size_override("font_size", 13)
        row.add_child(label)

        var steamID: String = friend.get(&"steam_id", "")
        if !steamID.is_empty():
            var invBtn: Button = Button.new()
            invBtn.text = "Invite"
            invBtn.mouse_filter = Control.MOUSE_FILTER_STOP
            invBtn.pressed.connect(_on_lobby_invite.bind(steamID))
            row.add_child(invBtn)


func _on_lobby_invite(steamID: String) -> void:
    CoopManager.steamBridge.invite_friend(steamID, _on_lobby_invite_result)


func _on_lobby_invite_result(response: Dictionary) -> void:
    if response.get(&"ok", false):
        CoopManager._log("Invite sent")
    else:
        CoopManager._log("Invite failed: %s" % response.get(&"error", "unknown"))


func _on_lobby_select_world() -> void:
    _free_dialog(lobbyPanel)
    lobbyPanel = null
    _lobbyPlayerList = null
    _lobbyFriendList = null
    show_world_picker()


func _on_lobby_back() -> void:
    if CoopManager.is_session_active():
        CoopManager.disconnect_session()
    _free_dialog(lobbyPanel)
    lobbyPanel = null
    _lobbyPlayerList = null
    _lobbyFriendList = null
    _show_mp_submenu_if_on_menu()


## Non-loopback IPv4 addresses (LAN + Tailscale).

func on_world_selected(worldId: String) -> void:
    hide_world_picker()
    _update_world_last_played(worldId)
    CoopManager.saveMirror.set_active_world(worldId)

    # Mirror the world dir into user:// so vanilla Loader picks up its saves.
    CoopManager.saveMirror.wipe_user_saves()
    CoopManager.saveMirror.mirror_world_to_user(worldId)

    if CoopManager.is_session_active():
        CoopManager.finalize_host()
    else:
        CoopManager.host_game(CoopManager.DEFAULT_PORT, pendingHostUseSteam)

    # Resume from the most recently visited shelter (or Cabin if none).
    var loader: Node = get_node_or_null(PATH_LOADER_ABS)
    if loader == null:
        return
    var shelter: String = loader.ValidateShelter() if loader.has_method(&"ValidateShelter") else ""
    if shelter.is_empty():
        shelter = "Cabin"
    loader.LoadScene(shelter)




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
    # Only path today is the menu-side lobby browser dialog; inline F10 panel was removed.
    var pool: Array[Button] = menuLobbyLabelPool
    var container: VBoxContainer = menuLobbyList

    if idx < pool.size():
        pool[idx].show()
        return pool[idx]

    var btn: Button = Button.new()
    btn.name = "LobbyBtn%d" % idx
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    if container != null:
        container.add_child(btn)
    pool.append(btn)
    return btn
