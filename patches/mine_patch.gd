## Patch for [code]Mine.gd[/code] — co-op detonation sync.
##
## Overrides:
## [br]- [method Detonate]: host broadcasts detonation to all clients
## [br]- [method InstantDetonate]: host broadcasts instant detonation to all clients
##
## Mine detonation is host-authoritative. Clients receive detonation events
## and play the VFX/physics locally. Original behaviour preserved when not
## in a co-op session.
extends "res://Scripts/Mine.gd"

var _cm: Node
## Scene-relative path, cached at _ready.
var _cachedPath: String = ""


func _ready() -> void:
    super._ready()
    _cachedPath = get_tree().current_scene.get_path_to(self)


func _ensure_cm() -> void:
    if is_instance_valid(_cm):
        return
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager"):
            _cm = child
            return


func Detonate() -> void:
    _ensure_cm()
    if is_instance_valid(_cm) && _cm.is_session_active():
        if _cm.isHost:
            _cm.worldState.broadcast_mine_detonate(_cachedPath, false)
            super.Detonate()
        else:
            # Client requests host to detonate — don't trigger locally.
            _cm.worldState.request_mine_detonate.rpc_id(1, _cachedPath, false)
        return
    super.Detonate()


func InstantDetonate() -> void:
    _ensure_cm()
    if is_instance_valid(_cm) && _cm.is_session_active():
        if _cm.isHost:
            _cm.worldState.broadcast_mine_detonate(_cachedPath, true)
            super.InstantDetonate()
        else:
            _cm.worldState.request_mine_detonate.rpc_id(1, _cachedPath, true)
        return
    super.InstantDetonate()
