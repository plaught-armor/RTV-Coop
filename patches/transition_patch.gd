## Patch for [code]Transition.gd[/code] — independent map transitions in co-op.
## Each player transitions on their own via [code]super.Interact()[/code]. The
## original Interact() handles saving, simulation updates, and scene loading
## correctly for each player independently. After the save commits, we mirror
## user://*.tres into the per-world dir so the world persists separately.
extends "res://Scripts/Transition.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready():
    super._ready()


## Lazy lookup of CoopManager — needed because inject_manager may not have
## reached this Transition node yet when the player interacts.
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


func Interact():
    super.Interact()
    _ensure_cm()
    if !is_instance_valid(_cm):
        return
    # Vanilla Interact already saved Character/World/Shelter to user://. Mirror
    # those into the appropriate persistent dir based on session type.
    if _cm.is_session_active() && _cm.isHost:
        _cm.mirror_user_to_world()
    elif !_cm.is_session_active():
        _cm.mirror_user_to_solo()
