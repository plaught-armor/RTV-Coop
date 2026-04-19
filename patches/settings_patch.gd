## Patch for [code]Settings.gd[/code] — restructures the in-game pause/settings
## screen as a vertical TabContainer with grouped categories, and adds a
## "Multiplayer" tab for co-op host/join controls.
##
## Vanilla Settings has 17 sections in flat rows which is cluttered. We move
## each existing section Control into a logical tab group. Reparenting nodes
## preserves the @onready references held by Settings.gd (Godot tracks by
## object pointer, not path), so all vanilla settings continue working.
extends "res://Scripts/Settings.gd"

var _cm: Node
## Path-based mapping from group name to the section node names inside
## Settings/Row_NN that should land in that tab. static var (not const)
## because const Array[Array] inner arrays are mutable shared refs per
## Godot #61274 — accidental mutation would corrupt every Settings instance.
static var TAB_GROUPS: Array[Array] = [
    ["Multiplayer", []],
    ["Controls", ["Inputs", "Mouse"]],
    ["Audio", ["Audio", "Music"]],
    ["Camera", ["Camera", "Image"]],
    ["HUD", ["HUD", "Tooltip", "PIP"]],
    ["Graphics", ["Display", "Frames", "Rendering", "Lighting", "Antialiasing"]],
    ["Effects", ["Shadows", "Water", "AO", "Color"]],
]


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    super._ready()
    _restructure_into_tabs.call_deferred()


## Tracks the currently-shown tab content panel so we can hide/show on click.
var _tabPanels: Dictionary[String, Control] = {}
var _tabButtons: Dictionary[String, Button] = {}
var _activeTab: String = ""


## Walks the existing Settings layout, finds each grouped section by name, and
## reparents it into a vertical-tab layout (custom-built since Godot 4's
## TabContainer only supports horizontal tabs). Idempotent — if the layout
## already exists, returns immediately. Skipped on the main menu so that
## Settings stays vanilla there; only the in-game pause version uses tabs.
func _restructure_into_tabs() -> void:
    if get_node_or_null("CoopTabs") != null:
        return
    if gameData != null && gameData.menu:
        return  # main menu — keep vanilla Settings layout

    var origBox: Node = get_node_or_null("Settings")
    if origBox == null:
        push_warning("[settings_patch] Settings BoxContainer not found, aborting")
        return

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

    # Left column: vertical tab button list.
    var tabBar: VBoxContainer = VBoxContainer.new()
    tabBar.name = "TabBar"
    tabBar.custom_minimum_size = Vector2(200, 0)
    tabBar.add_theme_constant_override("separation", 4)
    tabRoot.add_child(tabBar)

    # Right column: content stack (only one panel visible at a time).
    var contentArea: Control = Control.new()
    contentArea.name = "ContentArea"
    contentArea.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    contentArea.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabRoot.add_child(contentArea)

    # Hide vanilla layout — the original sections still exist, we just move them.
    origBox.hide()

    for group: Array in TAB_GROUPS:
        var groupName: String = group[0]
        var sectionNames: Array = group[1]

        # Tab button on the left — centered text to match game's button style.
        var tabBtn: Button = Button.new()
        tabBtn.text = groupName
        tabBtn.custom_minimum_size = Vector2(0, 36)
        tabBtn.alignment = HORIZONTAL_ALIGNMENT_CENTER
        tabBtn.pressed.connect(_show_tab.bind(groupName))
        tabBar.add_child(tabBtn)
        _tabButtons[groupName] = tabBtn

        # Content panel on the right (scrollable)
        var panel: ScrollContainer = ScrollContainer.new()
        panel.name = groupName + "_Panel"
        panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        panel.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        panel.hide()
        contentArea.add_child(panel)
        _tabPanels[groupName] = panel

        # Two-column grid so sections sit side-by-side instead of stacked.
        # Multiplayer tab keeps single-column (it's content, not settings).
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
                # Each section's children use anchor-based layout (CENTER +
                # pixel offsets), so the section needs explicit dimensions
                # or those children collapse to 0×0 and overlap. Tight sizing
                # keeps the grid compact (no gaping empty space between cells).
                (section as Control).custom_minimum_size = Vector2(420, 180)
                (section as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL

    # Show first tab by default.
    if !TAB_GROUPS.is_empty():
        _show_tab(TAB_GROUPS[0][0])

    # Exit buttons (Main Menu / Quit Game) — pulled out of the tab system so
    # they're always visible at the bottom of the pause menu.
    _build_exit_bar(origBox, outer)


## Pulls the Main Menu and Quit Game buttons out of the original Exit section
## and places them in a centered row anchored to the bottom of the pause menu.
func _build_exit_bar(origBox: Node, outer: Control) -> void:
    var exitSection: Node = _find_section(origBox, "Exit")
    if exitSection == null:
        return
    var exitGrid: Node = exitSection.get_node_or_null("Settings")
    var menuBtn: Node = exitGrid.get_node_or_null("Menu") if exitGrid != null else null
    var quitBtn: Node = exitGrid.get_node_or_null("Quit") if exitGrid != null else null
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


## Shows the named tab's content panel and hides all others.
func _show_tab(groupName: String) -> void:
    if _activeTab == groupName:
        return
    _activeTab = groupName
    for name: String in _tabPanels:
        var panel: Control = _tabPanels[name]
        if is_instance_valid(panel):
            panel.visible = (name == groupName)
    for name: String in _tabButtons:
        var btn: Button = _tabButtons[name]
        if is_instance_valid(btn):
            btn.modulate = Color(1, 1, 1, 1) if name == groupName else Color(1, 1, 1, 0.6)


## Finds a named section anywhere inside the original Settings BoxContainer.
## Sections live as direct children of Settings or Settings/Row_NN.
func _find_section(box: Node, sectionName: String) -> Node:
    var direct: Node = box.get_node_or_null(sectionName)
    if direct != null:
        return direct
    for child: Node in box.get_children():
        var nested: Node = child.get_node_or_null(sectionName)
        if nested != null:
            return nested
    return null


## Custom Controls tab layout: Inputs key bindings on the left, Mouse sliders
## + Inputs Modes (toggles) stacked on the right. Splits Inputs's children so
## the toggles visually group with the Mouse settings.
func _build_controls_tab(origBox: Node, panel: ScrollContainer) -> void:
    var inputs: Node = _find_section(origBox, "Inputs")
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

    if inputs != null:
        # Inputs scene contains: Header, Panel (key bindings), Modes
        # (toggles), Reset (button). We split: Panel + Header + Reset go left,
        # Modes goes right with Mouse.
        var header: Node = inputs.get_node_or_null("Header")
        var inputsPanel: Node = inputs.get_node_or_null("Panel")
        var modes: Node = inputs.get_node_or_null("Modes")
        var resetBtn: Node = inputs.get_node_or_null("Reset")

        if header != null:
            header.reparent(leftCol)
            (header as Control).show()
        if inputsPanel != null:
            inputsPanel.reparent(leftCol)
            (inputsPanel as Control).show()
            # Inputs/Panel is layout_mode=0 (free positioning) with fixed
            # offsets — switch to container-managed sizing so it fills the
            # left column instead of a 348×598 fixed rect.
            (inputsPanel as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
            (inputsPanel as Control).custom_minimum_size = Vector2(0, 480)
            (inputsPanel as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
            (inputsPanel as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
            # The MarginContainer inside also has layout_mode=0 — make it
            # follow its parent (the Panel) so it fills properly too.
            var margin: Node = inputsPanel.get_node_or_null("Margin")
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

        inputs.hide()  # empty wrapper, keep hidden

    if mouse != null:
        mouse.reparent(rightCol)
        (mouse as Control).show()
        (mouse as Control).custom_minimum_size = Vector2(0, 200)
        (mouse as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Builds the Multiplayer tab content. Two columns: left has session controls,
## right has a Steam friends list with inline Invite buttons.
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


## Left column: title, status label, host/join/action rows, connected players list.
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


## Host (Steam) + Host (IP) buttons side by side.
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


## Direct-join: address input, port input, Join button.
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
    portInput.placeholder_text = str(_cm.DEFAULT_PORT)
    portInput.custom_minimum_size = Vector2(60, 36)
    portInput.mouse_filter = Control.MOUSE_FILTER_STOP
    joinRow.add_child(portInput)

    var joinBtn: Button = Button.new()
    joinBtn.text = "Join"
    joinBtn.custom_minimum_size = Vector2(60, 36)
    joinBtn.pressed.connect(_on_mp_direct_join)
    joinRow.add_child(joinBtn)


## Disconnect + Logs buttons.
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


## Connected players header + scrolling list.
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


## Right column: friends list header, hint label, scrolling invite list.
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
## Maps Steam ID → TextureRect so we can patch in late-arriving avatars
## without waiting for the next 5s friend list rebuild.
var _avatarSlots: Dictionary[String, TextureRect] = {}


## Polls the coop session state every ~0.5s and refreshes the MP tab labels
## and button enable states. Also re-fetches the friends list every 5s while
## a session is active so invite buttons reflect online/in-game status.
func _process(_delta: float) -> void:
    # Skip the whole tick when the Settings panel isn't visible — the player
    # isn't paused and doesn't need the MP status poll.
    if !visible:
        return
    # Patch in late-arriving avatars every frame — cheap, no IPC.
    _patch_pending_avatars()
    if Engine.get_process_frames() % 30 != 0:
        return
    _refresh_mp_status()
    _maybe_refresh_friends()


func _refresh_mp_status() -> void:
    if !is_instance_valid(_cm):
        return
    var statusLabel: Label = find_child("MPStatus", true, false) as Label
    var hostBtn: Button = find_child("MPHostBtn", true, false) as Button
    var hostIpBtn: Button = find_child("MPHostIpBtn", true, false) as Button
    var disconnectBtn: Button = find_child("MPDisconnectBtn", true, false) as Button
    var ipInfo: VBoxContainer = find_child("MPIpInfo", true, false) as VBoxContainer
    var active: bool = _cm.is_session_active()
    if statusLabel != null:
        if active:
            var role: String = "Host" if _cm.isHost else "Client"
            statusLabel.text = "%s — %d peer(s)" % [role, _cm.connectedPeers.size()]
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
    if !active || !_cm.isHost || _cm._pendingHostUseSteam:
        ipInfo.hide()
        return
    # Only rebuild when first shown or peer count changes.
    if ipInfo.visible && ipInfo.get_child_count() > 0:
        return
    ipInfo.show()
    for child: Node in ipInfo.get_children():
        child.queue_free()
    var port: int = _cm.DEFAULT_PORT
    for addr: String in _cm.get_sharable_addresses():
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
        copyBtn.set_meta(&"copyText", text)
        copyBtn.pressed.connect(_on_copy_ip.bind(copyBtn))
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
    # Local player first.
    list.add_child(_make_player_row(_cm.localPeerId, _cm.get_local_name(), true))
    for peerId: int in _cm.connectedPeers:
        var peerName: String = _cm.peerNames.get(peerId, "Player %d" % peerId)
        list.add_child(_make_player_row(peerId, peerName, false))


func _make_player_row(peerId: int, displayName: String, isLocal: bool) -> HBoxContainer:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)

    var avatar: TextureRect = TextureRect.new()
    avatar.custom_minimum_size = Vector2(28, 28)
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    var steamId: String = _cm.peerSteamIDs.get(peerId, "")
    if isLocal:
        steamId = _cm.steamBridge.localSteamID if _cm.steamBridge.is_ready() else ""
    if !steamId.is_empty():
        var cached: Texture2D = _cm.avatarCache.get(steamId)
        if cached != null:
            avatar.texture = cached
        else:
            _cm.fetch_avatar(steamId)
    row.add_child(avatar)

    var nameLabel: Label = Label.new()
    nameLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    nameLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    var suffix: String = " (You)" if isLocal else ""
    if peerId == 1 && !isLocal:
        suffix += " — Host"
    elif isLocal && _cm.isHost:
        suffix += " — Host"
    nameLabel.text = "%s%s" % [displayName, suffix]
    row.add_child(nameLabel)

    return row


func _maybe_refresh_friends() -> void:
    if !is_instance_valid(_cm) || !is_instance_valid(_cm.steamBridge):
        return
    var hint: Label = find_child("MPFriendsHint", true, false) as Label
    var friendList: VBoxContainer = find_child("MPFriendsList", true, false) as VBoxContainer
    var canInvite: bool = _cm.is_session_active() && _cm.isHost && _cm.steamBridge.is_ready()
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
    _cm.steamBridge.get_friends(_on_friends_received)


func _on_friends_received(response: Dictionary) -> void:
    # Callback fires asynchronously after an IPC round-trip — this Settings
    # node may have been freed (pause menu closed) in the meantime.
    if !is_inside_tree():
        return
    var friendList: VBoxContainer = find_child("MPFriendsList", true, false) as VBoxContainer
    if friendList == null:
        return
    if !response.get(&"ok", false):
        return
    # Clear and rebuild the list. Friend lists are short (~50 max) so we just
    # rebuild rather than diffing.
    for child: Node in friendList.get_children():
        child.queue_free()
    _avatarSlots.clear()
    var friends: Array = response.get(&"data", [])
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

    # Populate from friend data (reuses cached avatars when possible).
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
    var cached: Texture2D = _cm.avatarCache.get(steamID)
    if cached != null:
        avatar.texture = cached
    elif !steamID.is_empty():
        _cm.fetch_avatar(steamID)
        _avatarSlots[steamID] = avatar  # patch in once IPC fetch completes

    inviteBtn.pressed.connect(_on_invite_friend.bind(steamID, friendName))
    return row


## Walks pending avatar slots and assigns the texture once the cache fills.
## Called from _process so late-arriving avatars appear without needing a
## full friend-list rebuild.
func _patch_pending_avatars() -> void:
    if _avatarSlots.is_empty() || !is_instance_valid(_cm):
        return
    var resolved: Array[String] = []
    for steamID: String in _avatarSlots:
        var tex: Texture2D = _cm.avatarCache.get(steamID)
        if tex == null:
            continue
        var slot: TextureRect = _avatarSlots[steamID]
        if is_instance_valid(slot):
            slot.texture = tex
        resolved.append(steamID)
    for sid: String in resolved:
        _avatarSlots.erase(sid)


func _on_invite_friend(steamID: String, friendName: String) -> void:
    if !is_instance_valid(_cm) || steamID.is_empty():
        return
    _cm.steamBridge.invite_friend(steamID, _on_invite_sent.bind(friendName))


func _on_invite_sent(response: Dictionary, friendName: String) -> void:
    if !is_instance_valid(_cm):
        return
    if response.get(&"ok", false):
        _cm._log("Invite sent to %s" % friendName)
    else:
        _cm._log("Invite failed: %s" % response.get(&"error", "unknown"))


## Override vanilla Menu/Quit/Return-from-warning handlers so our CoopTabs
## layout is shown/hidden correctly (vanilla targets `settings`, the flat
## BoxContainer that we hid during restructure).
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
    var tabs: Node = get_node_or_null("CoopTabs")
    if tabs != null:
        (tabs as Control).hide()
    var exitBar: Node = get_node_or_null("ExitBar")
    if exitBar != null:
        (exitBar as Control).hide()


func _show_coop_tabs() -> void:
    var tabs: Node = get_node_or_null("CoopTabs")
    if tabs != null:
        (tabs as Control).show()
    var exitBar: Node = get_node_or_null("ExitBar")
    if exitBar != null:
        (exitBar as Control).show()


func _on_mp_host() -> void:
    if !is_instance_valid(_cm) || _cm.is_session_active():
        return
    _cm.host_game()


func _on_mp_host_ip() -> void:
    if !is_instance_valid(_cm) || _cm.is_session_active():
        return
    _cm.host_game(_cm.DEFAULT_PORT, false)


func _on_mp_direct_join() -> void:
    if !is_instance_valid(_cm) || _cm.is_session_active():
        return
    var addrInput: LineEdit = find_child("MPAddrInput", true, false) as LineEdit
    var portInput: LineEdit = find_child("MPPortInput", true, false) as LineEdit
    var addr: String = addrInput.text.strip_edges() if addrInput != null else ""
    if addr.is_empty():
        addr = "127.0.0.1"
    var port: int = _cm.DEFAULT_PORT
    if portInput != null && !portInput.text.strip_edges().is_empty():
        port = int(portInput.text.strip_edges())
    _cm.join_game(addr, port, true)


func _on_mp_disconnect() -> void:
    if !is_instance_valid(_cm) || !_cm.is_session_active():
        return
    _cm.disconnect_session()
    var ipInfo: VBoxContainer = find_child("MPIpInfo", true, false) as VBoxContainer
    if ipInfo != null:
        ipInfo.hide()
        for child: Node in ipInfo.get_children():
            child.queue_free()


func _on_mp_logs() -> void:
    if !is_instance_valid(_cm):
        return
    _cm.collect_logs()


func _on_copy_ip(btn: Button) -> void:
    DisplayServer.clipboard_set(btn.get_meta(&"copyText", ""))


