## Patch for Settings.gd — regroups pause UI into vertical tabs and adds a Multiplayer tab.
extends "res://Scripts/Settings.gd"

# var (not const): Godot #61274 makes const Array[Array] inner arrays shared mutable refs.
var TAB_GROUPS: Array[Array] = [
    ["Multiplayer", []],
    ["Controls", ["Inputs", "Mouse"]],
    ["Audio", ["Audio", "Music"]],
    ["Camera", ["Camera", "Image"]],
    ["HUD", ["HUD", "Tooltip", "PIP"]],
    ["Graphics", ["Display", "Frames", "Rendering", "Lighting", "Antialiasing"]],
    ["Effects", ["Shadows", "Water", "AO", "Color"]],
]



const _DEFAULT_PORT_FALLBACK: int = 9050

const PATH_COOP_TABS: NodePath = ^"CoopTabs"
const PATH_SETTINGS: NodePath = ^"Settings"
const PATH_EXIT_BAR: NodePath = ^"ExitBar"
const PATH_HEADER: NodePath = ^"Header"
const PATH_PANEL: NodePath = ^"Panel"
const PATH_MODES: NodePath = ^"Modes"
const PATH_RESET: NodePath = ^"Reset"
const PATH_MARGIN: NodePath = ^"Margin"
const PATH_MENU_BTN: NodePath = ^"Menu"
const PATH_QUIT_BTN: NodePath = ^"Quit"

const PATH_ROOT_MAP_WORLD: NodePath = ^"/root/Map/World"
const PATH_ROOT_MENU: NodePath = ^"/root/Menu"


func _default_port() -> int:
    return CoopManager.DEFAULT_PORT if true else _DEFAULT_PORT_FALLBACK


# Null-guards the /root/Map/World and /root/Menu lookups base does without fallback.
func _ready() -> void:
    await get_tree().create_timer(0.1, false).timeout
    if !is_instance_valid(self):
        return
    currentRID = get_tree().get_root().get_viewport_rid()

    if !gameData.menu:
        world = get_node_or_null(PATH_ROOT_MAP_WORLD)
    else:
        mainMenu = get_node_or_null(PATH_ROOT_MENU)

    if pause != null:
        if !gameData.menu:
            pause.show()
        else:
            pause.hide()

    if menu != null && quit != null:
        if !gameData.menu:
            menu.disabled = false
            quit.disabled = false
        else:
            menu.disabled = true
            quit.disabled = true

    GetMonitors()
    GetWindowSizes()

    preferences = Preferences.Load() as Preferences
    LoadPreferences()

    if blocker != null:
        blocker.mouse_filter = MOUSE_FILTER_IGNORE

    _restructure_into_tabs.call_deferred()

    # Immediate friends fetch so the list paints before the user dismisses the menu.
    if !visibility_changed.is_connected(_on_settings_visibility_changed):
        visibility_changed.connect(_on_settings_visibility_changed)


func _on_settings_visibility_changed() -> void:
    if !visible:
        return
    # Paint cache first for instant feedback; async fetch replaces with fresh state.
    _paint_friends_from_cache()
    _lastFriendRefreshMs = 0
    _maybe_refresh_friends()


func _paint_friends_from_cache() -> void:
    if !is_instance_valid(CoopManager) || !is_instance_valid(CoopManager.steamBridge):
        return
    var raw: Variant = CoopManager.steamBridge.friendsCache
    var cached: Array = raw as Array
    if cached.is_empty():
        return
    _on_friends_received({&"ok": true, &"data": cached})


## Guards the !gameData.menu branch that would crash if interface is null.
func LoadPreferences() -> void:
    if gameData.menu or interface != null:
        super.LoadPreferences()
        return
    _load_prefs_without_interface()


## Mirrors base LoadPreferences without the interface-dependent block (Settings.gd:216-220).
func _load_prefs_without_interface() -> void:
    if preferences == null:
        return
    if masterSlider != null:
        masterSlider.value = preferences.masterVolume
    AudioServer.set_bus_volume_db(masterBus, linear_to_db(preferences.masterVolume))
    AudioServer.set_bus_mute(masterBus, preferences.masterVolume < 0.01)
    if ambientSlider != null:
        ambientSlider.value = preferences.ambientVolume
    AudioServer.set_bus_volume_db(ambientBus, linear_to_db(preferences.ambientVolume))
    AudioServer.set_bus_mute(ambientBus, preferences.ambientVolume < 0.01)
    if musicSlider != null:
        musicSlider.value = preferences.musicVolume
    AudioServer.set_bus_volume_db(musicBus, linear_to_db(preferences.musicVolume))
    AudioServer.set_bus_mute(musicBus, preferences.musicVolume < 0.01)


var _tabPanels: Dictionary[String, Control] = {}
var _tabButtons: Dictionary[String, Button] = {}
var _activeTab: String = ""


## Reparents existing sections into a vertical-tab layout (Godot 4 TabContainer is horizontal only).
func _restructure_into_tabs() -> void:
    if get_node_or_null(PATH_COOP_TABS) != null:
        return
    if gameData != null && gameData.menu:
        return

    var origBox: Node = get_node_or_null(PATH_SETTINGS)
    if origBox == null:
        push_warning("[settings_patch] Settings BoxContainer not found, aborting")
        return

    # NOTE: reparent/add_child below triggers a cascade of "Lambda capture at
    # index 0 was freed" errors from base-game / modloader inline lambdas
    # connected to tree-mutation signals. Attempted to prune them up front
    # but there's no public API to inspect lambda captures, and scorched-
    # earth disconnect broke C++ internal signal handlers. Filter via log
    # grep (per .wolf/debugging_guide.md) — noise only, not functional.

    var gameTheme: Theme = load("res://UI/Themes/Theme.tres")

    # Outer container — centers the tab layout on screen rather than spanning
    # edge-to-edge. Full-rect so it catches input everywhere.
    var outer: Control = Control.new()
    outer.name = "CoopTabs"
    outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    if gameTheme != null:
        outer.theme = gameTheme
    add_child(outer)

    var tabRoot: HBoxContainer = HBoxContainer.new()
    tabRoot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    tabRoot.grow_horizontal = Control.GROW_DIRECTION_BOTH
    tabRoot.grow_vertical = Control.GROW_DIRECTION_BOTH
    tabRoot.custom_minimum_size = Vector2(1100, 640)
    tabRoot.add_theme_constant_override("separation", 24)
    outer.add_child(tabRoot)

    var tabBar: VBoxContainer = VBoxContainer.new()
    tabBar.name = "TabBar"
    tabBar.custom_minimum_size = Vector2(200, 0)
    tabBar.add_theme_constant_override("separation", 4)
    tabRoot.add_child(tabBar)

    var contentArea: Control = Control.new()
    contentArea.name = "ContentArea"
    contentArea.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    contentArea.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabRoot.add_child(contentArea)

    origBox.hide()

    for group: Array in TAB_GROUPS:
        var groupName: String = group[0]
        var sectionNames: Array = group[1]

        var tabBtn: Button = Button.new()
        tabBtn.text = groupName
        tabBtn.custom_minimum_size = Vector2(0, 36)
        tabBtn.alignment = HORIZONTAL_ALIGNMENT_CENTER
        tabBtn.pressed.connect(_show_tab.bind(groupName))
        tabBar.add_child(tabBtn)
        _tabButtons[groupName] = tabBtn

        var panel: ScrollContainer = ScrollContainer.new()
        panel.name = groupName + "_Panel"
        panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        panel.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        panel.hide()
        contentArea.add_child(panel)
        _tabPanels[groupName] = panel

        var panelBox: Container
        if groupName == "Multiplayer":
            panelBox = VBoxContainer.new()
            panelBox.add_theme_constant_override("separation", 16)
        else:
            panelBox = GridContainer.new()
            (panelBox as GridContainer).columns = 2
            panelBox.add_theme_constant_override("h_separation", 0)
            panelBox.add_theme_constant_override("v_separation", 0)
        panelBox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        panel.add_child(panelBox)

        if groupName == "Multiplayer":
            _build_multiplayer_tab(panelBox)
            continue

        if groupName == "Controls":
            _build_controls_tab(origBox, panel)
            continue

        for sectionName: String in sectionNames:
            var section: Node = _find_section(origBox, sectionName)
            if section == null:
                continue
            section.reparent(panelBox)
            if section is Control:
                section.show()
                # Sections use anchor-based layout; explicit sizing keeps children from collapsing.
                (section as Control).custom_minimum_size = Vector2(420, 180)
                (section as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL

    if !TAB_GROUPS.is_empty():
        _show_tab(TAB_GROUPS[0][0])

    _build_exit_bar(origBox, outer)


func _build_exit_bar(origBox: Node, outer: Control) -> void:
    var exitSection: Node = _find_section(origBox, "Exit")
    if exitSection == null:
        return
    var exitGrid: Node = exitSection.get_node_or_null(PATH_SETTINGS)
    var menuBtn: Node = exitGrid.get_node_or_null(PATH_MENU_BTN) if exitGrid != null else null
    var quitBtn: Node = exitGrid.get_node_or_null(PATH_QUIT_BTN) if exitGrid != null else null
    if menuBtn == null && quitBtn == null:
        return

    var bar: HBoxContainer = HBoxContainer.new()
    bar.name = "ExitBar"
    bar.add_theme_constant_override("separation", 12)
    bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
    bar.offset_top = -64
    bar.offset_bottom = -16
    bar.offset_left = -200
    bar.offset_right = 200
    outer.add_child(bar)

    if menuBtn != null:
        menuBtn.reparent(bar)
        (menuBtn as Control).custom_minimum_size = Vector2(180, 40)
        (menuBtn as Control).show()
    if quitBtn != null:
        quitBtn.reparent(bar)
        (quitBtn as Control).custom_minimum_size = Vector2(180, 40)
        (quitBtn as Control).show()


func _show_tab(groupName: String) -> void:
    if _activeTab == groupName:
        return
    _activeTab = groupName
    for panel_name: String in _tabPanels:
        var panel: Control = _tabPanels[panel_name]
        if is_instance_valid(panel):
            panel.visible = (panel_name == groupName)
    for button_name: String in _tabButtons:
        var btn: Button = _tabButtons[button_name]
        if is_instance_valid(btn):
            btn.modulate = Color(1, 1, 1, 1) if button_name == groupName else Color(1, 1, 1, 0.6)


func _find_section(box: Node, sectionName: String) -> Node:
    var path: NodePath = NodePath(sectionName)
    var direct: Node = box.get_node_or_null(path)
    if direct != null:
        return direct
    for child: Node in box.get_children():
        var nested: Node = child.get_node_or_null(path)
        if nested != null:
            return nested
    return null


func _build_controls_tab(origBox: Node, panel: ScrollContainer) -> void:
    var settings_inputs: Node = _find_section(origBox, "Inputs")
    var mouse: Node = _find_section(origBox, "Mouse")

    var hbox: HBoxContainer = HBoxContainer.new()
    hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hbox.add_theme_constant_override("separation", 24)
    panel.add_child(hbox)

    var leftCol: VBoxContainer = VBoxContainer.new()
    leftCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    leftCol.custom_minimum_size = Vector2(420, 0)
    leftCol.add_theme_constant_override("separation", 8)
    hbox.add_child(leftCol)

    var rightCol: VBoxContainer = VBoxContainer.new()
    rightCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rightCol.custom_minimum_size = Vector2(420, 0)
    rightCol.add_theme_constant_override("separation", 8)
    hbox.add_child(rightCol)

    if settings_inputs != null:
        var header: Node = settings_inputs.get_node_or_null(PATH_HEADER)
        var inputsPanel: Node = settings_inputs.get_node_or_null(PATH_PANEL)
        var modes: Node = settings_inputs.get_node_or_null(PATH_MODES)
        var resetBtn: Node = settings_inputs.get_node_or_null(PATH_RESET)

        if header != null:
            header.reparent(leftCol)
            (header as Control).show()
        if inputsPanel != null:
            inputsPanel.reparent(leftCol)
            (inputsPanel as Control).show()
            # Inputs/Panel is layout_mode=0; switch to container-managed sizing.
            (inputsPanel as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
            (inputsPanel as Control).custom_minimum_size = Vector2(0, 480)
            (inputsPanel as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
            (inputsPanel as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
            var margin: Node = inputsPanel.get_node_or_null(PATH_MARGIN)
            if margin != null:
                (margin as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        if resetBtn != null:
            resetBtn.reparent(leftCol)
            (resetBtn as Control).show()

        if modes != null:
            modes.reparent(rightCol)
            (modes as Control).show()
            (modes as Control).custom_minimum_size = Vector2(0, 130)
            (modes as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL

        settings_inputs.hide()

    if mouse != null:
        mouse.reparent(rightCol)
        (mouse as Control).show()
        (mouse as Control).custom_minimum_size = Vector2(0, 200)
        (mouse as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _build_multiplayer_tab(parent: VBoxContainer) -> void:
    var outerHBox: HBoxContainer = HBoxContainer.new()
    outerHBox.add_theme_constant_override("separation", 24)
    outerHBox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(outerHBox)

    var leftCol: VBoxContainer = VBoxContainer.new()
    leftCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    leftCol.custom_minimum_size = Vector2(360, 0)
    leftCol.add_theme_constant_override("separation", 8)
    outerHBox.add_child(leftCol)

    var rightCol: VBoxContainer = VBoxContainer.new()
    rightCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rightCol.custom_minimum_size = Vector2(360, 0)
    rightCol.add_theme_constant_override("separation", 8)
    outerHBox.add_child(rightCol)

    _build_mp_left_column(leftCol)
    _build_mp_right_column(rightCol)


func _build_mp_left_column(leftCol: VBoxContainer) -> void:
    var title: Label = Label.new()
    title.text = "Multiplayer"
    title.add_theme_font_size_override("font_size", 20)
    leftCol.add_child(title)

    var subtitle: Label = Label.new()
    subtitle.text = "Co-op session"
    subtitle.modulate = Color(1, 1, 1, 0.5)
    subtitle.add_theme_font_size_override("font_size", 12)
    leftCol.add_child(subtitle)

    var statusLabel: Label = Label.new()
    statusLabel.name = "MPStatus"
    statusLabel.text = "Disconnected"
    leftCol.add_child(statusLabel)

    _build_mp_host_row(leftCol)
    _build_mp_join_row(leftCol)

    var ipInfo: VBoxContainer = VBoxContainer.new()
    ipInfo.name = "MPIpInfo"
    ipInfo.hide()
    leftCol.add_child(ipInfo)

    _build_mp_action_row(leftCol)
    _build_mp_players_section(leftCol)


func _build_mp_host_row(leftCol: VBoxContainer) -> void:
    var hostRow: HBoxContainer = HBoxContainer.new()
    hostRow.add_theme_constant_override("separation", 8)
    leftCol.add_child(hostRow)

    var hostBtn: Button = Button.new()
    hostBtn.name = "MPHostBtn"
    hostBtn.text = "Host (Steam)"
    hostBtn.custom_minimum_size = Vector2(0, 40)
    hostBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hostBtn.pressed.connect(_on_mp_host)
    hostRow.add_child(hostBtn)

    var hostIpBtn: Button = Button.new()
    hostIpBtn.name = "MPHostIpBtn"
    hostIpBtn.text = "Host (IP)"
    hostIpBtn.custom_minimum_size = Vector2(0, 40)
    hostIpBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hostIpBtn.pressed.connect(_on_mp_host_ip)
    hostRow.add_child(hostIpBtn)


func _build_mp_join_row(leftCol: VBoxContainer) -> void:
    var joinRow: HBoxContainer = HBoxContainer.new()
    joinRow.add_theme_constant_override("separation", 4)
    leftCol.add_child(joinRow)

    var addrInput: LineEdit = LineEdit.new()
    addrInput.name = "MPAddrInput"
    addrInput.placeholder_text = "127.0.0.1"
    addrInput.custom_minimum_size = Vector2(0, 36)
    addrInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    addrInput.mouse_filter = Control.MOUSE_FILTER_STOP
    joinRow.add_child(addrInput)

    var portInput: LineEdit = LineEdit.new()
    portInput.name = "MPPortInput"
    portInput.placeholder_text = str(_default_port())
    portInput.custom_minimum_size = Vector2(60, 36)
    portInput.mouse_filter = Control.MOUSE_FILTER_STOP
    joinRow.add_child(portInput)

    var joinBtn: Button = Button.new()
    joinBtn.text = "Join"
    joinBtn.custom_minimum_size = Vector2(60, 36)
    joinBtn.pressed.connect(_on_mp_direct_join)
    joinRow.add_child(joinBtn)


func _build_mp_action_row(leftCol: VBoxContainer) -> void:
    var actionRow: HBoxContainer = HBoxContainer.new()
    actionRow.add_theme_constant_override("separation", 8)
    leftCol.add_child(actionRow)

    var disconnectBtn: Button = Button.new()
    disconnectBtn.name = "MPDisconnectBtn"
    disconnectBtn.text = "Disconnect"
    disconnectBtn.custom_minimum_size = Vector2(0, 40)
    disconnectBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    disconnectBtn.pressed.connect(_on_mp_disconnect)
    actionRow.add_child(disconnectBtn)

    var logsBtn: Button = Button.new()
    logsBtn.text = "Logs"
    logsBtn.custom_minimum_size = Vector2(0, 40)
    logsBtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    logsBtn.pressed.connect(_on_mp_logs)
    actionRow.add_child(logsBtn)


func _build_mp_players_section(leftCol: VBoxContainer) -> void:
    var playersHeader: Label = Label.new()
    playersHeader.text = "Connected Players"
    playersHeader.add_theme_font_size_override("font_size", 16)
    leftCol.add_child(playersHeader)

    var playersScroll: ScrollContainer = ScrollContainer.new()
    playersScroll.name = "MPPlayersScroll"
    playersScroll.custom_minimum_size = Vector2(0, 200)
    playersScroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    leftCol.add_child(playersScroll)

    var playersList: VBoxContainer = VBoxContainer.new()
    playersList.name = "MPPlayersList"
    playersList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    playersList.add_theme_constant_override("separation", 4)
    playersScroll.add_child(playersList)


func _build_mp_right_column(rightCol: VBoxContainer) -> void:
    var friendsLabel: Label = Label.new()
    friendsLabel.text = "Invite Friends"
    friendsLabel.add_theme_font_size_override("font_size", 16)
    rightCol.add_child(friendsLabel)

    var friendsHint: Label = Label.new()
    friendsHint.name = "MPFriendsHint"
    friendsHint.text = "Host a session to invite friends."
    friendsHint.modulate = Color(1, 1, 1, 0.5)
    friendsHint.add_theme_font_size_override("font_size", 12)
    rightCol.add_child(friendsHint)

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.name = "MPFriendsScroll"
    scroll.custom_minimum_size = Vector2(0, 380)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    rightCol.add_child(scroll)

    var friendList: VBoxContainer = VBoxContainer.new()
    friendList.name = "MPFriendsList"
    friendList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    friendList.add_theme_constant_override("separation", 4)
    scroll.add_child(friendList)


var _lastFriendRefreshMs: int = 0
const FRIEND_REFRESH_INTERVAL_MS: int = 5000
# Maps Steam ID to TextureRect to patch in avatars that arrive after list rebuild.
var _avatarSlots: Dictionary[String, TextureRect] = {}


func _process(_delta: float) -> void:
    if !visible:
        return
    _patch_pending_avatars()
    if Engine.get_process_frames() % 30 != 0:
        return
    _refresh_mp_status()
    _maybe_refresh_friends()


func _refresh_mp_status() -> void:
    if !is_instance_valid(CoopManager):
        return
    var statusLabel: Label = find_child("MPStatus", true, false) as Label
    var hostBtn: Button = find_child("MPHostBtn", true, false) as Button
    var hostIpBtn: Button = find_child("MPHostIpBtn", true, false) as Button
    var disconnectBtn: Button = find_child("MPDisconnectBtn", true, false) as Button
    var ipInfo: VBoxContainer = find_child("MPIpInfo", true, false) as VBoxContainer
    var active: bool = CoopManager.is_session_active()
    if statusLabel != null:
        if active:
            var role: String = "Host" if CoopManager.isHost else "Client"
            var remoteCount: int = maxi(0, CoopManager.active_peer_count() - 1)
            statusLabel.text = "%s — %d peer(s)" % [role, remoteCount]
            statusLabel.modulate = Color(0.5, 0.9, 0.5, 0.9)
        else:
            statusLabel.text = "Disconnected"
            statusLabel.modulate = Color(1, 1, 1, 0.6)
    if hostBtn != null:
        hostBtn.disabled = active
    if hostIpBtn != null:
        hostIpBtn.disabled = active
    if disconnectBtn != null:
        disconnectBtn.disabled = !active
    _refresh_ip_info(ipInfo, active)
    _refresh_players_list(active)


func _refresh_ip_info(ipInfo: VBoxContainer, active: bool) -> void:
    if ipInfo == null:
        return
    if !active || !CoopManager.isHost || CoopManager._pendingHostUseSteam:
        ipInfo.hide()
        return
    if ipInfo.visible && ipInfo.get_child_count() > 0:
        return
    ipInfo.show()
    for child: Node in ipInfo.get_children():
        child.queue_free()
    var port: int = _default_port()
    for addr: String in CoopManager.get_sharable_addresses():
        var row: HBoxContainer = HBoxContainer.new()
        ipInfo.add_child(row)
        var text: String = "%s:%d" % [addr, port]
        var label: Label = Label.new()
        label.text = text
        label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        label.add_theme_font_size_override("font_size", 12)
        row.add_child(label)
        var copyBtn: Button = Button.new()
        copyBtn.text = "Copy"
        copyBtn.mouse_filter = Control.MOUSE_FILTER_STOP
        # Bind String value to avoid dangling Callable on row free.
        copyBtn.pressed.connect(_on_copy_ip_text.bind(text))
        row.add_child(copyBtn)


func _refresh_players_list(active: bool) -> void:
    var list: VBoxContainer = find_child("MPPlayersList", true, false) as VBoxContainer
    if list == null:
        return
    for child: Node in list.get_children():
        child.queue_free()
    if !active:
        var hint: Label = Label.new()
        hint.text = "No active session."
        hint.modulate = Color(1, 1, 1, 0.5)
        hint.add_theme_font_size_override("font_size", 12)
        list.add_child(hint)
        return
    list.add_child(_make_player_row(CoopManager.localPeerId, CoopManager.get_local_name(), true))
    var localPid: int = CoopManager.localPeerId
    for peerId: int in CoopManager.peerGodotIds:
        if peerId == -1 || peerId == localPid:
            continue
        list.add_child(_make_player_row(peerId, CoopManager.get_peer_name(peerId), false))


func _make_player_row(peerId: int, displayName: String, isLocal: bool) -> HBoxContainer:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)

    var avatar: TextureRect = TextureRect.new()
    avatar.custom_minimum_size = Vector2(28, 28)
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    var steamId: String = ""
    var peerSlotIdx: int = CoopManager.peer_idx(peerId)
    if peerSlotIdx >= 0:
        steamId = CoopManager.peerSteamIDs[peerSlotIdx]
    if isLocal:
        steamId = CoopManager.steamBridge.localSteamID if CoopManager.steamBridge.is_ready() else ""
    if !steamId.is_empty():
        var cached: Texture2D = null
        if CoopManager.avatarCache.has(steamId):
            cached = CoopManager.avatarCache[steamId]
        if cached != null:
            avatar.texture = cached
        else:
            CoopManager.fetch_avatar(steamId)
    row.add_child(avatar)

    var nameLabel: Label = Label.new()
    nameLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    nameLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    var suffix: String = " (You)" if isLocal else ""
    if peerId == 1 && !isLocal:
        suffix += " — Host"
    elif isLocal && CoopManager.isHost:
        suffix += " — Host"
    nameLabel.text = "%s%s" % [displayName, suffix]
    row.add_child(nameLabel)

    return row


func _maybe_refresh_friends() -> void:
    if !is_instance_valid(CoopManager) || !is_instance_valid(CoopManager.steamBridge):
        return
    var hint: Label = find_child("MPFriendsHint", true, false) as Label
    var friendList: VBoxContainer = find_child("MPFriendsList", true, false) as VBoxContainer
    var canInvite: bool = CoopManager.is_session_active() && CoopManager.isHost && CoopManager.steamBridge.is_ready()
    if hint != null:
        hint.visible = !canInvite
    if friendList != null && !canInvite:
        for child: Node in friendList.get_children():
            child.queue_free()
        return
    if !canInvite:
        return
    var now: int = Time.get_ticks_msec()
    if now - _lastFriendRefreshMs < FRIEND_REFRESH_INTERVAL_MS:
        return
    _lastFriendRefreshMs = now
    CoopManager.steamBridge.get_friends(_on_friends_received)


func _on_friends_received(response: Dictionary) -> void:
    # Async callback: Settings may have been freed between request and response.
    if !is_inside_tree():
        return
    var friendList: VBoxContainer = find_child("MPFriendsList", true, false) as VBoxContainer
    if friendList == null:
        return
    if !response.get(&"ok", false):
        return
    for child: Node in friendList.get_children():
        child.queue_free()
    _avatarSlots.clear()
    var friends: Array = response.get(&"data", []) as Array
    for friend: Dictionary in friends:
        var row: HBoxContainer = _make_friend_row(friend)
        friendList.add_child(row)


func _make_friend_row(friend: Dictionary) -> HBoxContainer:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    var avatar: TextureRect = TextureRect.new()
    avatar.custom_minimum_size = Vector2(28, 28)
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    row.add_child(avatar)

    var nameLabel: Label = Label.new()
    nameLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    nameLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(nameLabel)

    var inviteBtn: Button = Button.new()
    inviteBtn.text = "Invite"
    inviteBtn.custom_minimum_size = Vector2(72, 28)
    row.add_child(inviteBtn)

    var friendName: String = friend.get(&"name", "Unknown")
    var state: int = friend.get(&"state", 0)
    var gameID: String = friend.get(&"game_id", "")
    var inGame: bool = !gameID.is_empty()
    var stateText: String = ""
    var nameColor: Color = Color("#57cbde")
    if inGame:
        stateText = " (In-Game)"
        nameColor = Color("#90ba3c")
    else:
        match state:
            1:
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
                nameColor = Color("#57cbde")
    nameLabel.text = "%s%s" % [friendName, stateText]
    nameLabel.add_theme_color_override("font_color", nameColor)

    var steamID: String = friend.get(&"steam_id", "")
    var cached: Texture2D = null
    if CoopManager.avatarCache.has(steamID):
        cached = CoopManager.avatarCache[steamID]
    if cached != null:
        avatar.texture = cached
    elif !steamID.is_empty():
        CoopManager.fetch_avatar(steamID)
        _avatarSlots[steamID] = avatar

    inviteBtn.pressed.connect(_on_invite_friend.bind(steamID, friendName))
    return row


func _patch_pending_avatars() -> void:
    if _avatarSlots.is_empty() || !is_instance_valid(CoopManager):
        return
    var resolved: Array[String] = []
    for steamID: String in _avatarSlots:
        var tex: Texture2D = null
        if CoopManager.avatarCache.has(steamID):
            tex = CoopManager.avatarCache[steamID]
        if tex == null:
            continue
        var slot: TextureRect = _avatarSlots[steamID]
        if is_instance_valid(slot):
            slot.texture = tex
        resolved.append(steamID)
    for sid: String in resolved:
        _avatarSlots.erase(sid)


func _on_invite_friend(steamID: String, friendName: String) -> void:
    if !is_instance_valid(CoopManager) || steamID.is_empty():
        return
    CoopManager.steamBridge.invite_friend(steamID, _on_invite_sent.bind(friendName))


func _on_invite_sent(response: Dictionary, friendName: String) -> void:
    if !is_instance_valid(CoopManager):
        return
    if response.get(&"ok", false):
        CoopManager._log("Invite sent to %s" % friendName)
    else:
        CoopManager._log("Invite failed: %s" % response.get(&"error", "unknown"))


## Override Menu/Quit/Return handlers since vanilla targets the hidden flat BoxContainer.
func _on_menu_pressed() -> void:
    if gameData.shelter || gameData.tutorial:
        _on_exit_menu_pressed()
        return
    _hide_coop_tabs()
    warning.show()
    exitMenu.show()
    exitQuit.hide()
    pause.hide()
    PlayClick()


func _on_quit_pressed() -> void:
    if gameData.shelter || gameData.tutorial:
        _on_exit_quit_pressed()
        return
    _hide_coop_tabs()
    warning.show()
    exitMenu.hide()
    exitQuit.show()
    pause.hide()
    PlayClick()


func _on_exit_return_pressed() -> void:
    _show_coop_tabs()
    if warning != null:
        warning.hide()
    if pause != null:
        pause.show()
    PlayClick()


func _hide_coop_tabs() -> void:
    var tabs: Node = get_node_or_null(PATH_COOP_TABS)
    if tabs != null:
        (tabs as Control).hide()
    var exitBar: Node = get_node_or_null(PATH_EXIT_BAR)
    if exitBar != null:
        (exitBar as Control).hide()


func _show_coop_tabs() -> void:
    var tabs: Node = get_node_or_null(PATH_COOP_TABS)
    if tabs != null:
        (tabs as Control).show()
    var exitBar: Node = get_node_or_null(PATH_EXIT_BAR)
    if exitBar != null:
        (exitBar as Control).show()


func _on_mp_host() -> void:
    if !is_instance_valid(CoopManager) || CoopManager.is_session_active():
        return
    CoopManager.host_game()


func _on_mp_host_ip() -> void:
    if !is_instance_valid(CoopManager) || CoopManager.is_session_active():
        return
    CoopManager.host_game(_default_port(), false)


func _on_mp_direct_join() -> void:
    if !is_instance_valid(CoopManager) || CoopManager.is_session_active():
        return
    var addrInput: LineEdit = find_child("MPAddrInput", true, false) as LineEdit
    var portInput: LineEdit = find_child("MPPortInput", true, false) as LineEdit
    var addr: String = addrInput.text.strip_edges() if addrInput != null else ""
    if addr.is_empty():
        addr = "127.0.0.1"
    var port: int = _default_port()
    if portInput != null && !portInput.text.strip_edges().is_empty():
        port = int(portInput.text.strip_edges())
    CoopManager.join_game(addr, port, true)


func _on_mp_disconnect() -> void:
    if !CoopManager.is_session_active():
        return
    CoopManager.disconnect_session()
    var ipInfo: VBoxContainer = find_child("MPIpInfo", true, false) as VBoxContainer
    if ipInfo != null:
        ipInfo.hide()
        for child: Node in ipInfo.get_children():
            child.queue_free()


func _on_mp_logs() -> void:
    if !is_instance_valid(CoopManager):
        return
    CoopManager.logCollector.collect()


func _on_copy_ip_text(copyText: String) -> void:
    DisplayServer.clipboard_set(copyText)
