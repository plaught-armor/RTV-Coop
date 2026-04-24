## Top-right HUD overlay showing keybind hints, players, and ping; F12 toggles.
extends VBoxContainer




var pingTimer: float = 0.0
var hudVisible: bool = true
var inGameplay: bool = false
var lastScenePath: String = ""
const PING_INTERVAL: float = 1.0
const PATH_CONTROLLER: NodePath = ^"Core/Controller"
var peerPings: Dictionary[int, int] = { }
var labelPool: Array[HBoxContainer] = []
var keybindLabel: Label = null
var sleepOverlay: CanvasLayer = null
var sleepLabel: Label = null
const HINT_COLOR: Color = Color(0.6, 0.6, 0.6, 0.6)
const PLAYER_COLOR: Color = Color(0.8, 1.0, 0.8, 0.8)
const SLEEP_LABEL_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const SLEEP_OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.9)


func _ready() -> void:
    anchor_left = 1.0
    anchor_right = 1.0
    anchor_top = 0.0
    offset_left = -220
    offset_right = -10
    offset_top = 10
    mouse_filter = Control.MOUSE_FILTER_IGNORE

    _build_keybind_label()
    _build_sleep_overlay()


# Keybind hint — first child of coop_hud so it sits above Connected Players
# in the same top-right block. F12 hides it alongside player roster.
func _build_keybind_label() -> void:
    keybindLabel = Label.new()
    keybindLabel.name = "KeybindLabel"
    var font: FontFile = load("res://Fonts/Lora-Regular.ttf") as FontFile
    if font != null:
        keybindLabel.add_theme_font_override("font", font)
    keybindLabel.add_theme_font_size_override("font_size", 12)
    keybindLabel.add_theme_color_override("font_color", HINT_COLOR)
    keybindLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    keybindLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(keybindLabel)
    move_child(keybindLabel, 0)
    _update_keybind_label()


func _update_keybind_label() -> void:
    if keybindLabel == null:
        return
    var toggleText: String = "Hide Connected" if hudVisible else "Show Connected"
    keybindLabel.text = "[F11] Coop Menu | [F12] %s" % toggleText


func _build_sleep_overlay() -> void:
    sleepOverlay = CanvasLayer.new()
    sleepOverlay.name = "SleepOverlay"
    sleepOverlay.layer = 90
    sleepOverlay.visible = false
    CoopManager.add_child(sleepOverlay)

    sleepLabel = Label.new()
    sleepLabel.name = "SleepLabel"
    sleepLabel.add_theme_font_size_override(&"font_size", 22)
    sleepLabel.add_theme_color_override(&"font_color", SLEEP_LABEL_COLOR)
    sleepLabel.add_theme_color_override(&"font_outline_color", SLEEP_OUTLINE_COLOR)
    sleepLabel.add_theme_constant_override(&"outline_size", 5)
    sleepLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    sleepLabel.anchor_left = 0.0
    sleepLabel.anchor_right = 1.0
    sleepLabel.anchor_top = 0.0
    sleepLabel.offset_top = 80
    sleepLabel.offset_bottom = 130
    sleepLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    sleepOverlay.add_child(sleepLabel)


func _input(event: InputEvent) -> void:
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if event.keycode == KEY_F12:
        hudVisible = !hudVisible
        visible = hudVisible
        _update_keybind_label()


func _process(delta: float) -> void:
    _update_sleep_overlay()
    if !is_instance_valid(CoopManager) || !hudVisible:
        if visible:
            visible = false
        return

    # Cache inGameplay on scene change; avoids per-frame get_node_or_null.
    var scene: Node = get_tree().current_scene
    var scenePath: String = scene.scene_file_path if is_instance_valid(scene) else ""
    if scenePath != lastScenePath:
        lastScenePath = scenePath
        inGameplay = is_instance_valid(scene) && scene.get_node_or_null(PATH_CONTROLLER) != null
        if keybindLabel != null:
            keybindLabel.visible = inGameplay

    if !inGameplay:
        if visible:
            visible = false
        return
    if !visible:
        visible = true

    if !CoopManager.isActive:
        hide_all_player_labels()
        return

    pingTimer += delta
    if pingTimer < PING_INTERVAL:
        return
    pingTimer = 0.0

    update_pings()
    update_player_labels()


func update_pings() -> void:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if !(peer is ENetMultiplayerPeer):
        return
    var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer

    peerPings.clear()
    var localPid: int = CoopManager.localPeerId
    for peerId: int in CoopManager.peerGodotIds:
        if peerId == -1 || peerId == localPid:
            continue
        var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
        if enetPeer != null:
            peerPings[peerId] = roundi(
                enetPeer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
            )


func update_player_labels() -> void:
    var idx: int = 0

    var localRow: HBoxContainer = get_pooled_row(idx)
    idx += 1
    var localAvatar: TextureRect = localRow.get_child(0)
    var localLabel: Label = localRow.get_child(1)
    var localName: String = CoopManager.get_local_name()
    localLabel.text = "%s (Host)" % localName if CoopManager.isHost else localName
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
        var row: HBoxContainer = get_pooled_row(idx)
        idx += 1
        var avatar: TextureRect = row.get_child(0)
        var label: Label = row.get_child(1)
        var peerName: String = CoopManager.get_peer_name(peerId)
        var ping: int = -1
        if peerPings.has(peerId):
            ping = peerPings[peerId]
        label.text = "%s: %dms" % [peerName, ping] if ping >= 0 else "%s: ..." % peerName
        var tex: ImageTexture = CoopManager.get_peer_avatar(peerId)
        if tex != null:
            avatar.texture = tex
            avatar.show()
        else:
            avatar.hide()

    for i: int in range(idx, labelPool.size()):
        labelPool[i].hide()


func get_pooled_row(idx: int) -> HBoxContainer:
    if idx < labelPool.size():
        labelPool[idx].show()
        return labelPool[idx]

    var row: HBoxContainer = HBoxContainer.new()
    row.name = "PlayerRow"
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.alignment = BoxContainer.ALIGNMENT_END

    var avatar: TextureRect = TextureRect.new()
    avatar.name = "Avatar"
    avatar.custom_minimum_size = Vector2(18, 18)
    avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(avatar)

    var label: Label = Label.new()
    label.name = "NameLabel"
    var font: FontFile = load("res://Fonts/Lora-Regular.ttf") as FontFile
    if font != null:
        label.add_theme_font_override("font", font)
    label.add_theme_font_size_override("font_size", 14)
    label.add_theme_color_override("font_color", PLAYER_COLOR)
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)

    add_child(row)
    labelPool.append(row)
    return row


func hide_all_player_labels() -> void:
    for row: HBoxContainer in labelPool:
        row.hide()


func _update_sleep_overlay() -> void:
    if !is_instance_valid(sleepOverlay) || !is_instance_valid(sleepLabel):
        return
    if !is_instance_valid(CoopManager) || !CoopManager.isActive:
        sleepOverlay.visible = false
        return
    var readyIds: Array = CoopManager.get_meta(&"coop_sleep_ready_ids", []) as Array
    var total: int = int(CoopManager.get_meta(&"coop_sleep_total", 0))
    if total <= 1 || readyIds.is_empty():
        sleepOverlay.visible = false
        return
    sleepLabel.text = "Sleeping: %d/%d ready" % [readyIds.size(), total]
    sleepOverlay.visible = true
