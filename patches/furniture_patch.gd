## Patch for Furniture.gd — syncs placement (ResetMove) and pickup (Catalog); host-authoritative.
@tool
extends "res://Scripts/Furniture.gd"


var _cm: Node


func _ensure_cm() -> bool:
    if is_instance_valid(_cm):
        return true
    _cm = _CML.find(get_tree())
    return _cm != null


func StartMove() -> void:
    super.StartMove()
    if !_ensure_cm() || !_cm.is_session_active():
        return
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene) || !is_instance_valid(owner):
        return
    # Last-grab-wins: grabbing forces any other holder to drop (no host arbitration).
    _cm.worldState.sync_furniture_grab.rpc(scene.get_path_to(owner))


func ResetMove() -> void:
    super.ResetMove()
    if !_ensure_cm() || !_cm.is_session_active():
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


## Drop locally without broadcasting when another peer grabs this piece.
func force_release() -> void:
    if !isMoving:
        return
    super.ResetMove()


func Catalog() -> void:
    # Capture path before super: super calls owner.queue_free().
    var furniturePath: String = ""
    if _ensure_cm() && _cm.is_session_active() && is_instance_valid(owner):
        var scene: Node = get_tree().current_scene
        if is_instance_valid(scene):
            furniturePath = scene.get_path_to(owner)
    super.Catalog()
    if furniturePath.is_empty():
        return
    if _cm.isHost:
        _cm.worldState.sync_furniture_catalog.rpc(furniturePath)
    else:
        _cm.worldState.request_furniture_catalog.rpc_id(1, furniturePath)
