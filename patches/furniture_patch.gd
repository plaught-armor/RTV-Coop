## Co-op patch for Furniture.gd
##
## Syncs furniture placement and catalog (pickup) between peers.
## ResetMove → broadcasts final position/rotation to all peers.
## Catalog → broadcasts removal. Host-authoritative to prevent dupes.
## Intermediate movement during placement is local only.
extends "res://Scripts/Furniture.gd"


var _cm: Node


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


func StartMove() -> void:
    super.StartMove()
    _ensure_cm()
    if _cm == null || !_cm.is_session_active():
        return
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || !is_instance_valid(owner):
        return
    # Last-grab-wins lock: any peer grabbing this piece forces everyone else
    # currently holding it to drop. Host arbitration is overkill for 2–4
    # players; the window where two peers grab the same item in the same
    # frame is narrow enough that the visible yank is acceptable.
    _cm.worldState.sync_furniture_grab.rpc(scene.get_path_to(owner))


func ResetMove() -> void:
    super.ResetMove()
    _ensure_cm()
    if _cm == null || !_cm.is_session_active():
        return
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || !is_instance_valid(owner):
        return
    var furniturePath: String = scene.get_path_to(owner)
    var pos: Vector3 = owner.global_position
    var rotY: float = owner.global_rotation_degrees.y
    if _cm.isHost:
        _cm.worldState.sync_furniture_place.rpc(furniturePath, pos, rotY)
    else:
        _cm.worldState.request_furniture_place.rpc_id(1, furniturePath, pos, rotY)
    _cm.worldState.sync_furniture_release.rpc(furniturePath)


## Called by world_state when another peer grabs this piece while we're also
## in the middle of moving it. Drop locally so only the latest grabber owns
## the transform. Mirrors the body of super.ResetMove without broadcasting.
func force_release() -> void:
    if !isMoving:
        return
    super.ResetMove()


func Catalog() -> void:
    _ensure_cm()
    # Capture path before super — super calls owner.queue_free().
    var furniturePath: String = ""
    if _cm != null && _cm.is_session_active() && is_instance_valid(owner):
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            furniturePath = scene.get_path_to(owner)
    super.Catalog()
    if furniturePath.is_empty() || !is_instance_valid(_cm):
        return
    if _cm.isHost:
        _cm.worldState.sync_furniture_catalog.rpc(furniturePath)
    else:
        _cm.worldState.request_furniture_catalog.rpc_id(1, furniturePath)
