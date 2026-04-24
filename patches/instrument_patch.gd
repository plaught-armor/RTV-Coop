## Patch for Instrument.gd — edge-detects local audioPlayer start/stop and
## broadcasts a 3D audio clip so remote players hear it on the puppet body.
extends "res://Scripts/Instrument.gd"
const _CML: GDScript = preload("res://mod/autoload/coop_manager_locator.gd")

var _cm: Node = null
var _audioWasPlaying: bool = false


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func _physics_process(delta: float) -> void:
    super._physics_process(delta)
    if !_ensure_cm() || !_cm.is_session_active() || audioPlayer == null:
        return
    var nowPlaying: bool = audioPlayer.playing
    if nowPlaying == _audioWasPlaying:
        return
    _audioWasPlaying = nowPlaying
    var senderId: int = multiplayer.get_unique_id()
    if nowPlaying:
        var clip: AudioStream = audioPlayer.stream
        var clipPath: String = clip.resource_path if is_instance_valid(clip) else ""
        if clipPath.is_empty():
            return
        if _cm.isHost:
            _cm.worldState.broadcast_instrument_play.rpc(senderId, clipPath)
        else:
            _cm.worldState.request_instrument_play.rpc_id(1, clipPath)
    else:
        if _cm.isHost:
            _cm.worldState.broadcast_instrument_stop.rpc(senderId)
        else:
            _cm.worldState.request_instrument_stop.rpc_id(1)


func _exit_tree() -> void:
    if !_ensure_cm() || !_cm.is_session_active() || !_audioWasPlaying:
        return
    _audioWasPlaying = false
    var senderId: int = multiplayer.get_unique_id()
    if _cm.isHost:
        _cm.worldState.broadcast_instrument_stop.rpc(senderId)
    else:
        _cm.worldState.request_instrument_stop.rpc_id(1)
