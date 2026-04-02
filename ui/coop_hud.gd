## Always-visible HUD overlay in the top-right showing keybind hints,
## connected players, and their ping. [kbd]F12[/kbd] toggles visibility.
## Added as a child of [code]CoopManager[/code]'s [code]CanvasLayer[/code].
extends VBoxContainer

var pingTimer: float = 0.0
var hudVisible: bool = true
const PING_INTERVAL: float = 1.0
var peerPings: Dictionary[int, int] = { }
var labelPool: Array[Label] = []
var hintsLabel: Label = null
const HINT_COLOR: Color = Color(0.6, 0.6, 0.6, 0.6)
const PLAYER_COLOR: Color = Color(0.8, 1.0, 0.8, 0.8)


func _ready() -> void:
    anchor_left = 1.0
    anchor_right = 1.0
    anchor_top = 0.0
    offset_left = -220
    offset_right = -10
    offset_top = 10
    mouse_filter = Control.MOUSE_FILTER_IGNORE

    # Static keybind hints label (always at top of VBox)
    hintsLabel = Label.new()
    hintsLabel.add_theme_font_size_override("font_size", 12)
    hintsLabel.add_theme_color_override("font_color", HINT_COLOR)
    hintsLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hintsLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(hintsLabel)
    UpdateHints()


func _input(event: InputEvent) -> void:
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if event.keycode == KEY_F12:
        hudVisible = !hudVisible
        visible = hudVisible


func _process(delta: float) -> void:
    if !hudVisible || !IsInGameplay():
        if visible:
            visible = false
        return
    if !visible:
        visible = true

    UpdateHints()

    if !CoopManager.isActive:
        HideAllPlayerLabels()
        return

    pingTimer += delta
    if pingTimer < PING_INTERVAL:
        return
    pingTimer = 0.0

    UpdatePings()
    UpdatePlayerLabels()


## Updates the keybind hints based on connection and Steam state.
func UpdateHints() -> void:
    if CoopManager.isActive:
        hintsLabel.text = "INS Panel  |  F12 Hide"
    elif !CoopManager.DEBUG && !CoopManager.steamBridge.IsReady():
        if CoopManager.steamBridge.connected:
            hintsLabel.text = "Steam: verifying...  |  F12 Hide"
        elif CoopManager.steamBridge.connecting:
            hintsLabel.text = "Steam: connecting...  |  F12 Hide"
        else:
            hintsLabel.text = "Steam: offline  |  F12 Hide"
    else:
        hintsLabel.text = "INS Panel  |  F10 Host  |  F12 Hide"


func UpdatePings() -> void:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if !(peer is ENetMultiplayerPeer):
        return
    var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer

    for peerId: int in CoopManager.connectedPeers:
        var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
        if enetPeer != null:
            peerPings[peerId] = roundi(
                enetPeer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
            )

    for peerId: int in peerPings.keys():
        if peerId not in CoopManager.connectedPeers:
            peerPings.erase(peerId)


func UpdatePlayerLabels() -> void:
    var idx: int = 0

    var localLabel: Label = GetPooledLabel(idx)
    idx += 1
    var localName: String = CoopManager.GetLocalName()
    localLabel.text = "%s (Host)" % localName if CoopManager.isHost else localName

    for peerId: int in CoopManager.connectedPeers:
        var label: Label = GetPooledLabel(idx)
        idx += 1
        var peerName: String = CoopManager.GetPeerName(peerId)
        var ping: int = peerPings.get(peerId, -1)
        label.text = "%s: %dms" % [peerName, ping] if ping >= 0 else "%s: ..." % peerName

    for i: int in range(idx, labelPool.size()):
        labelPool[i].hide()


func GetPooledLabel(idx: int) -> Label:
    if idx < labelPool.size():
        labelPool[idx].show()
        return labelPool[idx]

    var label: Label = Label.new()
    label.add_theme_font_size_override("font_size", 14)
    label.add_theme_color_override("font_color", PLAYER_COLOR)
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(label)
    labelPool.append(label)
    return label


func HideAllPlayerLabels() -> void:
    for label: Label in labelPool:
        label.hide()


func IsInGameplay() -> bool:
    var scene: Node = get_tree().current_scene
    return is_instance_valid(scene) && scene.get_node_or_null("Core/Controller") != null
