## Patch for [code]Transition.gd[/code] — independent map transitions in co-op.
## Each player transitions on their own via [code]super.Interact()[/code]. The
## original Interact() handles saving, simulation updates, and scene loading
## correctly for each player independently. After the save commits, we mirror
## user://*.tres into the per-world dir so the world persists separately.
extends "res://Scripts/Transition.gd"

var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func _ready() -> void:
    super._ready()


## Lazy CoopManager lookup — inject_manager may not have reached this node yet.
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


func Interact() -> void:
    _ensure_cm()
    print("[TX] Interact begin nextMap=%s" % nextMap)
    # CLIENT in coop: don't run vanilla Interact's save block — it would
    # write replicated host state into the client's user:// and pollute
    # their solo save when they return to the menu. Just trigger the scene
    # change and let the host be authoritative.
    if is_instance_valid(_cm) && _cm.is_session_active() && !_cm.isHost:
        if locked:
            CheckKey()
            return
        Simulation.simulate = false
        if tutorialExit:
            Loader.LoadScene(nextMap)
        else:
            UpdateSimulation()
            Simulation.simulate = true
            gameData.currentMap = nextMap
            gameData.previousMap = currentMap
            gameData.energy -= energy
            gameData.hydration -= hydration
            Loader.LoadScene(nextMap)
        print("[TX] Interact end (client)")
        return

    super.Interact()
    if !is_instance_valid(_cm):
        print("[TX] Interact end (solo, no cm)")
        return
    # Vanilla Interact already saved Character/World/Shelter to user://. Mirror
    # those into the appropriate persistent dir based on session type.
    if _cm.is_session_active() && _cm.isHost:
        _cm.mirror_user_to_world()
    elif !_cm.is_session_active():
        _cm.mirror_user_to_solo()
    print("[TX] Interact end (host/solo)")
