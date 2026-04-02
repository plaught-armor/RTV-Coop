## Always-visible HUD overlay showing connected players and their ping.
## Added as a child of [code]CoopManager[/code]'s [code]CanvasLayer[/code].
extends VBoxContainer

var coopManager: Node = null
var pingTimer: float = 0.0
var hudVisible: bool = true
## How often to poll ENet peer round-trip times.
const PING_INTERVAL: float = 1.0
## Cached ping values per peer in milliseconds.
var peerPings: Dictionary = { }
## Pre-allocated label pool to avoid per-update allocation.
var labelPool: Array[Label] = []


func _ready() -> void:
	coopManager = get_node("/root/CoopManager")

	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	offset_left = -200
	offset_right = -10
	offset_top = 10
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _input(event: InputEvent) -> void:
	if !(event is InputEventKey) || !event.pressed || event.echo:
		return
	if event.keycode == KEY_F12:
		hudVisible = !hudVisible
		if !hudVisible:
			HideAllLabels()


func _process(delta: float) -> void:
	if !hudVisible || !coopManager.isActive:
		if get_child_count() > 0:
			HideAllLabels()
		return

	pingTimer += delta
	if pingTimer < PING_INTERVAL:
		return
	pingTimer = 0.0

	UpdatePings()
	UpdateLabels()


## Reads round-trip time from each connected [code]ENetPacketPeer[/code].
func UpdatePings() -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if !(peer is ENetMultiplayerPeer):
		return
	var enet: ENetMultiplayerPeer = peer as ENetMultiplayerPeer

	for peerId: int in coopManager.peers:
		var enetPeer: ENetPacketPeer = enet.get_peer(peerId)
		if enetPeer != null:
			peerPings[peerId] = roundi(
				enetPeer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
			)

	for peerId: int in peerPings.keys():
		if peerId not in coopManager.peers:
			peerPings.erase(peerId)


## Updates label text in-place using a pool. Grows pool if needed, hides extras.
func UpdateLabels() -> void:
	var idx: int = 0

	# Host line
	var hostLabel: Label = GetPooledLabel(idx)
	idx += 1
	if coopManager.isHost:
		hostLabel.text = "You (Host)"
	else:
		var hostPing: int = peerPings.get(1, -1)
		hostLabel.text = "Host: %dms" % hostPing if hostPing >= 0 else "Host: ..."

	# Peer lines
	for peerId: int in coopManager.peers:
		var label: Label = GetPooledLabel(idx)
		idx += 1
		var ping: int = peerPings.get(peerId, -1)
		label.text = "Player_%d: %dms" % [peerId, ping] if ping >= 0 else "Player_%d: ..." % peerId

	# Hide unused labels
	for i: int in range(idx, labelPool.size()):
		labelPool[i].hide()


## Returns the pooled label at [param idx], creating it if the pool is too small.
func GetPooledLabel(idx: int) -> Label:
	if idx < labelPool.size():
		labelPool[idx].show()
		return labelPool[idx]

	var label: Label = Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8, 0.8))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	labelPool.append(label)
	return label


func HideAllLabels() -> void:
	for label: Label in labelPool:
		label.hide()
