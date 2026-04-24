## Watches Instrument nodes for audioPlayer.playing transitions and broadcasts
## start/stop so remote peers hear it on the puppet rig. Replaces instrument_patch.
##
## Tracks each Instrument added to the scene via SceneTree.node_added, keyed
## by node instance. On each CoopManager._process tick, checks edge.
## Cleaned up on node removal.
extends RefCounted


const INSTRUMENT_SCRIPT_PATH: String = "res://Scripts/Instrument.gd"

# Tracked Instrument nodes -> was_playing bool.
var _watched: Dictionary = {}


func connect_tree() -> void:
    var tree: SceneTree = CoopManager.get_tree()
    if tree != null && !tree.node_added.is_connected(_on_node_added):
        tree.node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
    var script: Script = n.get_script()
    if script == null || script.resource_path != INSTRUMENT_SCRIPT_PATH:
        return
    _watched[n] = false


func poll() -> void:
    if !CoopManager.is_session_active():
        return
    var stale: Array = []
    for node: Node in _watched:
        if !is_instance_valid(node):
            stale.append(node)
            continue
        var audioPlayer: Node = node.get(&"audioPlayer")
        if audioPlayer == null:
            continue
        var nowPlaying: bool = audioPlayer.playing
        var wasPlaying: bool = _watched[node]
        if nowPlaying == wasPlaying:
            continue
        _watched[node] = nowPlaying
        _emit(node, audioPlayer, nowPlaying)
    for n: Node in stale:
        var wasPlaying: bool = _watched[n]
        _watched.erase(n)
        if wasPlaying:
            _emit_stop()


func _emit(_node: Node, audioPlayer: Node, nowPlaying: bool) -> void:
    var senderId: int = CoopManager.multiplayer.get_unique_id()
    if nowPlaying:
        var clip: AudioStream = audioPlayer.stream
        var clipPath: String = clip.resource_path if is_instance_valid(clip) else ""
        if clipPath.is_empty():
            return
        if CoopManager.isHost:
            CoopManager.worldState.broadcast_instrument_play.rpc(senderId, clipPath)
        else:
            CoopManager.worldState.request_instrument_play.rpc_id(1, clipPath)
    else:
        _emit_stop()


func _emit_stop() -> void:
    var senderId: int = CoopManager.multiplayer.get_unique_id()
    if CoopManager.isHost:
        CoopManager.worldState.broadcast_instrument_stop.rpc(senderId)
    else:
        CoopManager.worldState.request_instrument_stop.rpc_id(1)
