## Host/join panel for the co-op mod.
## [kbd]F9[/kbd] toggles the panel. [kbd]F10[/kbd] quick-hosts. [kbd]F11[/kbd] quick-joins
## using the address and port fields. Built programmatically — no [code].tscn[/code] needed.
extends Control

var panel: PanelContainer = null
var statusLabel: Label = null
var ipLabel: Label = null
var playerList: VBoxContainer = null
var addressInput: LineEdit = null
var portInput: LineEdit = null
var panelVisible: bool = false
var lastPeerCount: int = -1
var lastConnectionState: int = -1
## Pre-allocated label pool for the player list.
var playerLabelPool: Array[Label] = []


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    BuildUI()
    panel.hide()


func _input(event: InputEvent) -> void:
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return

    match event.keycode:
        KEY_F9:
            panelVisible = !panelVisible
            panel.visible = panelVisible
            if panelVisible:
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            else:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
        KEY_F10:
            OnHostPressed()
        KEY_F11:
            OnJoinPressed()


func BuildUI() -> void:
    panel = PanelContainer.new()
    panel.custom_minimum_size = Vector2(340, 320)
    panel.anchor_left = 1.0
    panel.anchor_right = 1.0
    panel.anchor_top = 0.0
    panel.anchor_bottom = 0.0
    panel.offset_left = -350
    panel.offset_right = -10
    panel.offset_top = 10
    panel.offset_bottom = 330
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

    ipLabel = Label.new()
    ipLabel.text = "Your IP: %s" % GetLocalIP()
    vbox.add_child(ipLabel)

    var copyBtn: Button = Button.new()
    copyBtn.text = "Copy IP"
    copyBtn.pressed.connect(OnCopyIP)
    vbox.add_child(copyBtn)

    vbox.add_child(HSeparator.new())

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

    var btnRow: HBoxContainer = HBoxContainer.new()
    vbox.add_child(btnRow)

    var hostBtn: Button = Button.new()
    hostBtn.text = "Host (F10)"
    hostBtn.pressed.connect(OnHostPressed)
    btnRow.add_child(hostBtn)

    var joinBtn: Button = Button.new()
    joinBtn.text = "Join (F11)"
    joinBtn.pressed.connect(OnJoinPressed)
    btnRow.add_child(joinBtn)

    var disconnectBtn: Button = Button.new()
    disconnectBtn.text = "Disconnect"
    disconnectBtn.pressed.connect(OnDisconnectPressed)
    btnRow.add_child(disconnectBtn)

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
            statusLabel.text = "Hosting on port %d (%d peers)" % [GetPort(), currentPeerCount]
        2:
            statusLabel.text = "Connected (id: %d)" % CoopManager.localPeerId

    UpdatePlayerList()


## Updates the player list using a label pool — no alloc/free churn on state change.
func UpdatePlayerList() -> void:
    var idx: int = 0

    if CoopManager.isActive:
        var localLabel: Label = GetPooledPlayerLabel(idx)
        idx += 1
        localLabel.text = "  You (id: %d)" % CoopManager.localPeerId

        for peerId: int in CoopManager.connectedPeers:
            var label: Label = GetPooledPlayerLabel(idx)
            idx += 1
            label.text = "  Player_%d" % peerId

    for i: int in range(idx, playerLabelPool.size()):
        playerLabelPool[i].hide()


func GetPooledPlayerLabel(idx: int) -> Label:
    if idx < playerLabelPool.size():
        playerLabelPool[idx].show()
        return playerLabelPool[idx]

    var label: Label = Label.new()
    playerList.add_child(label)
    playerLabelPool.append(label)
    return label


## Returns the port from the input field, clamped to valid range (1024-65535).
func GetPort() -> int:
    var portText: String = portInput.text if portInput != null else ""
    if portText.is_valid_int():
        return clampi(portText.to_int(), 1024, 65535)
    return CoopManager.DEFAULT_PORT


## Returns the address from the input field, or [code]127.0.0.1[/code] if empty.
func GetAddress() -> String:
    if addressInput != null && !addressInput.text.is_empty():
        return addressInput.text
    return "127.0.0.1"


## Returns the first non-loopback, non-IPv6 local IP address.
func GetLocalIP() -> String:
    for addr: String in IP.get_local_addresses():
        if addr.begins_with("127.") || addr.begins_with("::") || ":" in addr:
            continue
        return addr
    return "127.0.0.1"


func OnHostPressed() -> void:
    CoopManager.HostGame(GetPort())


func OnJoinPressed() -> void:
    CoopManager.JoinGame(GetAddress(), GetPort())


func OnDisconnectPressed() -> void:
    CoopManager.Disconnect()


func OnCopyIP() -> void:
    DisplayServer.clipboard_set(GetLocalIP())
