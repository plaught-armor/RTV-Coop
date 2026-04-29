## Hook callbacks for Furniture.gd — placement + pickup sync; host-authoritative.
## Replaces patches/furniture_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## `suppress_sync` flag lets world_state.gd call ResetMove() without echoing the
## broadcast back (replaces the old `force_release` helper method).
extends RefCounted


var _lib: Object = null
var _catalogPaths: Dictionary[Node, String] = {}
var suppress_sync: bool = false


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("furniture-startmove-post", _on_start_move_post)
    lib.hook("furniture-resetmove-post", _on_reset_move_post)
    lib.hook("furniture-catalog-pre", _on_catalog_pre)
    lib.hook("furniture-catalog-post", _on_catalog_post)


func _on_start_move_post() -> void:
    if suppress_sync:
        return
    if !CoopManager.is_session_active():
        return
    var f: Furniture = _lib._caller as Furniture
    if f == null || !is_instance_valid(f.owner):
        return
    var scene: Node = f.get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var path: String = scene.get_path_to(f.owner)
    CoopManager._log("[furniture] StartMove path=%s" % path)
    CoopManager.worldState.sync_furniture_grab.rpc(path)


func _on_reset_move_post() -> void:
    if suppress_sync:
        return
    if !CoopManager.is_session_active():
        return
    var f: Furniture = _lib._caller as Furniture
    if f == null || !is_instance_valid(f.owner):
        return
    var scene: Node = f.get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var furniturePath: String = scene.get_path_to(f.owner)
    var pos: Vector3 = f.owner.global_position
    var rotY: float = f.owner.global_rotation_degrees.y
    CoopManager._log("[furniture] ResetMove path=%s pos=%s host=%s" % [furniturePath, str(pos), str(CoopManager.isHost)])
    if CoopManager.isHost:
        CoopManager.worldState.sync_furniture_place.rpc(furniturePath, pos, rotY)
    else:
        CoopManager.worldState.request_furniture_place.rpc_id(1, furniturePath, pos, rotY)
    CoopManager.worldState.sync_furniture_release.rpc(furniturePath)


func _on_catalog_pre() -> void:
    var f: Furniture = _lib._caller as Furniture
    if f == null:
        return
    if !CoopManager.is_session_active() || !is_instance_valid(f.owner):
        return
    var scene: Node = f.get_tree().current_scene
    if is_instance_valid(scene):
        _catalogPaths[f] = scene.get_path_to(f.owner)


func _on_catalog_post() -> void:
    var f: Furniture = _lib._caller as Furniture
    if f == null:
        return
    var furniturePath: String = _catalogPaths[f] if _catalogPaths.has(f) else ""
    _catalogPaths.erase(f)
    if furniturePath.is_empty():
        return
    CoopManager._log("[furniture] Catalog path=%s host=%s" % [furniturePath, str(CoopManager.isHost)])
    if CoopManager.isHost:
        CoopManager.worldState.sync_furniture_catalog.rpc(furniturePath)
    else:
        CoopManager.worldState.request_furniture_catalog.rpc_id(1, furniturePath)
