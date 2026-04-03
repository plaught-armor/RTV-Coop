## Always-visible HUD overlay in the top-right showing keybind hints,
## connected players, and their ping. [kbd]F12[/kbd] toggles visibility.
## Added as a child of [code]CoopManager[/code]'s [code]CanvasLayer[/code].
extends VBoxContainer

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager

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
    update_hints()


func _input(event: InputEvent) -> void:
    if !(event is InputEventKey) || !event.pressed || event.echo:
        return
    if event.keycode == KEY_F12:
        hudVisible = !hudVisible
        visible = hudVisible


func _process(delta: float) -> void:
    if _cm == null || !hudVisible || !is_in_gameplay():
        if visible:
            visible = false
        return
    if !visible:
        visible = true

    update_hints()

    if !_cm.isActive:
        hide_all_player_labels()
        return

    pingTimer += delta
    if pingTimer < PING_INTERVAL:
        return
    pingTimer = 0.0

    update_pings()
    update_player_labels()


## Updates the keybind hints based on connection and Steam state.
func update_hints() -> void:
    if _cm.isActive:
        hintsLabel.text = "INS Multiplayer"
    elif !_cm.DEBUG && !_cm.steamBridge.is_ready():
        if _cm.steamBridge.connected:
            hintsLabel.text = "Steam: verifying..."
        elif _cm.steamBridge.connecting:
            hintsLabel.text = "Steam: connecting..."
        else:
            hintsLabel.text = "Steam: offline"
    else:
        hintsLabel.text = "INS Multiplayer"


func update_pings() -> void:
    var peer: MultiplayerPeer = multiplayer.multiplayer_peer
    if !(peer is ENetMultiplayerPeer):
        return
    var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer

    for peerId: int in _cm.connectedPeers:
        var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
        if enetPeer != null:
            peerPings[peerId] = roundi(
                enetPeer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
            )

    for peerId: int in peerPings.keys():
        if peerId not in _cm.connectedPeers:
            peerPings.erase(peerId)


func update_player_labels() -> void:
    var idx: int = 0

    var localLabel: Label = get_pooled_label(idx)
    idx += 1
    var localName: String = _cm.get_local_name()
    localLabel.text = "%s (Host)" % localName if _cm.isHost else localName

    for peerId: int in _cm.connectedPeers:
        var label: Label = get_pooled_label(idx)
        idx += 1
        var peerName: String = _cm.get_peer_name(peerId)
        var ping: int = peerPings.get(peerId, -1)
        label.text = "%s: %dms" % [peerName, ping] if ping >= 0 else "%s: ..." % peerName

    for i: int in range(idx, labelPool.size()):
        labelPool[i].hide()


func get_pooled_label(idx: int) -> Label:
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


func hide_all_player_labels() -> void:
    for label: Label in labelPool:
        label.hide()


func is_in_gameplay() -> bool:
    var scene: Node = get_tree().current_scene
    return is_instance_valid(scene) && scene.get_node_or_null("Core/Controller") != null
