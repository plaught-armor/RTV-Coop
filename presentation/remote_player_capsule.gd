## Remote player visual using a bare CapsuleMesh body + chest Marker3D weapon
## mount. No skeleton, no AI rig, no walk/run anims — set_active_weapon attaches
## a stripped FPS weapon rig (which carries its own AnimationPlayer for weapon
## anims). Animation state isn't yet network-synced; weapons play default Idle.
extends "res://mod/presentation/remote_player.gd"


const CAPSULE_HEIGHT: float = 1.8
const CAPSULE_RADIUS: float = 0.3
const CAPSULE_CHEST_Y: float = 1.3
const CAPSULE_WEAPON_MOUNT_NAME: StringName = &"WeaponMount"
const CAPSULE_BODY_NAME: String = "Capsule"

# RigManager.UpdateRig normally drives arm sleeve/glove materials from the
# local player's torso/hand equipment slots. On a peer we don't have that
# state, so apply the same defaults RigManager falls back to.
const FPS_DEFAULT_SLEEVES_PATH: String = "res://Items/Clothing/Jacket_M62/Files/MT_Jacket_M62_Sleeves.tres"
const FPS_DEFAULT_GLOVES_PATH: String = "res://Items/Clothing/Gloves_Leather/Files/MT_Gloves_Leather.tres"
const PATH_ARMS: NodePath = ^"Arms"


# Same node as modelRoot; capsule has no AI script attached.
var capsuleRoot: Node3D = null
var weaponMount: Marker3D = null
# AnimationPlayer harvested from the attached FPS weapon rig (per-weapon).
var weaponAnimPlayer: AnimationPlayer = null


func accepts_body(body: String) -> bool:
    return body == CAPSULE_BODY_NAME


func _spawn_rig(body: String) -> bool:
    if body != CAPSULE_BODY_NAME:
        return false
    var root: Node3D = Node3D.new()
    root.name = "Capsule"
    add_child(root)

    var meshInst: MeshInstance3D = MeshInstance3D.new()
    var capsule: CapsuleMesh = CapsuleMesh.new()
    capsule.radius = CAPSULE_RADIUS
    capsule.height = CAPSULE_HEIGHT
    meshInst.mesh = capsule
    meshInst.position.y = CAPSULE_HEIGHT * 0.5
    root.add_child(meshInst)

    # Marker3D ≈ BoneAttachment3D for a skeletonless rig — set_active_weapon
    # parents the FPS weapon rig here.
    var mount: Marker3D = Marker3D.new()
    mount.name = CAPSULE_WEAPON_MOUNT_NAME
    mount.position = Vector3(0.25, CAPSULE_CHEST_Y, -0.35)
    root.add_child(mount)

    capsuleRoot = root
    modelRoot = root
    meshNode = meshInst
    weaponMount = mount
    currentBody = CAPSULE_BODY_NAME
    return true


func _free_rig() -> void:
    if is_instance_valid(capsuleRoot):
        capsuleRoot.queue_free()
    capsuleRoot = null
    modelRoot = null
    meshNode = null
    weaponMount = null
    weaponAnimPlayer = null
    activeWeapon = null
    activeMuzzle = null
    currentBody = ""


func set_active_weapon(weaponName: String) -> void:
    if !is_instance_valid(weaponMount):
        return

    if is_instance_valid(activeWeapon):
        activeWeapon.queue_free()
    activeWeapon = null
    activeMuzzle = null
    weaponAnimPlayer = null

    if weaponName.is_empty() || !_is_valid_weapon_name(weaponName):
        return
    _attach_fps_rig(weaponMount, weaponName)
    _apply_attachments()


## Capsule-only: load the FPS weapon rig (which has full animations), strip its
## script + UI/camera coupling, force VisualInstance3D layers from FPS-only
## (layer 2) to default world (layer 1) so peers' world cameras render it,
## apply default sleeve/glove materials to the arm mesh.
func _attach_fps_rig(mount: Node, weaponName: String) -> void:
    var path: String = "res://Items/Weapons/%s/%s_Rig.tscn" % [weaponName, weaponName]
    if !ResourceLoader.exists(path):
        return
    var packed: PackedScene = load(path) as PackedScene
    if packed == null:
        return
    var rig: Node = packed.instantiate()
    if rig == null:
        return
    rig.name = &"_coop_dyn"
    # WeaponRig.gd reads gameData/UI nodes that don't exist on a peer — drop the
    # script so _ready/_input/_physics_process never fire.
    rig.set_script(null)
    _strip_rig_recursive(rig)
    _strip_fps_rig_recursive(rig)
    _force_world_layer_recursive(rig)
    if rig is Node3D:
        (rig as Node3D).transform = Transform3D.IDENTITY
    mount.add_child(rig)
    activeWeapon = rig as Node3D
    activeMuzzle = rig.get_node_or_null(PATH_MUZZLE) as Node3D
    _apply_default_arm_materials(rig)
    var rigAnim: AnimationPlayer = _find_anim_in_subtree(rig)
    if rigAnim != null:
        weaponAnimPlayer = rigAnim
        if rigAnim.has_animation(&"Idle"):
            rigAnim.play(&"Idle")


## FPS rigs bundle their source RigidBody3D + "Item" group, which makes
## Interactor pick them up through the local player's body.
func _strip_rig_recursive(node: Node) -> void:
    for g: StringName in node.get_groups():
        node.remove_from_group(g)
    if node is RigidBody3D:
        var rb: RigidBody3D = node
        rb.freeze = true
        rb.collision_layer = 0
        rb.collision_mask = 0
    elif node is CollisionObject3D:
        var co: CollisionObject3D = node
        co.collision_layer = 0
        co.collision_mask = 0
    for child: Node in node.get_children():
        _strip_rig_recursive(child)


## FPS rigs bundle Camera3D + spotlights + scope viewports that crash or
## misrender for a peer (no XR origin, no PIP shader binds). Strip them.
func _strip_fps_rig_recursive(node: Node) -> void:
    var trash: Array[Node] = []
    for child: Node in node.get_children():
        if child is Camera3D || child is Light3D || child is SubViewport:
            trash.append(child)
        else:
            _strip_fps_rig_recursive(child)
    for n: Node in trash:
        n.get_parent().remove_child(n)
        n.queue_free()


## FPS weapon rig meshes are authored on visibility layer 2 (FPS camera only).
## Peers' world cameras cull layer 2, so meshes invisible without this reset.
func _force_world_layer_recursive(node: Node) -> void:
    if node is VisualInstance3D:
        (node as VisualInstance3D).layers = 1
    for child: Node in node.get_children():
        _force_world_layer_recursive(child)


func _apply_default_arm_materials(rig: Node) -> void:
    var arms: MeshInstance3D = rig.get_node_or_null(PATH_ARMS) as MeshInstance3D
    if arms == null:
        for child: Node in rig.get_children():
            arms = _find_arms_recursive(child)
            if arms != null:
                break
    if arms == null:
        return
    var sleeves: Material = load(FPS_DEFAULT_SLEEVES_PATH) as Material
    var gloves: Material = load(FPS_DEFAULT_GLOVES_PATH) as Material
    if sleeves != null:
        arms.set_surface_override_material(0, sleeves)
    if gloves != null:
        arms.set_surface_override_material(1, gloves)


func _find_arms_recursive(node: Node) -> MeshInstance3D:
    if node is MeshInstance3D && node.name == &"Arms":
        return node as MeshInstance3D
    for child: Node in node.get_children():
        var found: MeshInstance3D = _find_arms_recursive(child)
        if found != null:
            return found
    return null


func _find_anim_in_subtree(root: Node) -> AnimationPlayer:
    if root is AnimationPlayer:
        return root as AnimationPlayer
    for child: Node in root.get_children():
        var found: AnimationPlayer = _find_anim_in_subtree(child)
        if found != null:
            return found
    return null
