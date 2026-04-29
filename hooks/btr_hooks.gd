## Hook callbacks for BTR.gd — host-authoritative; clients freeze + lerp host snapshots.
## Replaces patches/btr_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


const LERP_SPEED: float = 8.0

var _lib: Object = null
var _relPaths: Dictionary[Node, String] = {}


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("btr-_physics_process", _on_phys)
    lib.hook("btr-fire", _on_fire)


func _on_phys(delta: float) -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    var btr: Node3D = _lib._caller as Node3D
    if btr == null:
        return
    _lib.skip_super()
    if !btr.freeze:
        btr.freeze = true
    btr.Tires(delta)
    btr.Suspension(delta)
    btr.Audio(delta)
    _apply_host_snapshot(btr, delta)


func _apply_host_snapshot(btr: Node3D, delta: float) -> void:
    var path: String = _relPaths[btr] if _relPaths.has(btr) else ""
    if path.is_empty():
        var scene: Node = btr.get_tree().current_scene
        if is_instance_valid(scene):
            path = String(scene.get_path_to(btr))
            _relPaths[btr] = path
    if path.is_empty():
        return
    var snap: Dictionary = CoopManager.vehicleState.get_snapshot(path)
    if snap.is_empty():
        return
    var blend: float = clampf(delta * LERP_SPEED, 0.0, 1.0)
    btr.global_transform.origin = btr.global_transform.origin.lerp(snap.pos, blend)
    var targetBasis: Basis = Basis(snap.rot as Quaternion)
    btr.global_transform.basis = btr.global_transform.basis.slerp(targetBasis, blend)
    var towerNode: Node = btr.get_node_or_null(^"Chassis/Tower")
    if is_instance_valid(towerNode) && towerNode is Node3D:
        var t: Node3D = towerNode as Node3D
        t.rotation.y = lerp_angle(t.rotation.y, snap.turret as float, blend)


func _on_fire(_delta: float) -> void:
    if !CoopManager.is_session_active() || CoopManager.isHost:
        return
    _lib.skip_super()
