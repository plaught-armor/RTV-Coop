## Remote player visual: bare CapsuleMesh body + chest Marker3D weapon mount.
## set_active_weapon attaches a stripped FPS weapon rig (with its own
## AnimationPlayer + AnimationTree); set_active_anim_state mirrors the owner's
## current state-machine playback node onto that tree (Reload, Inspect, fire
## mode, etc) so weapon anims play in sync on the peer.
extends Node3D


# Shadow autoload identifier for production .vmz runs (no project setting registry).
var CoopManager: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"/root/CoopManager")


# Bit 19: ai_patch adds only this bit to fire/LOS masks so HitBody is invisible to everything else.
const COOP_HIT_LAYER: int = 1 << 19

const PATH_MUZZLE: NodePath = ^"Muzzle"
const PATH_HITBODY: NodePath = ^"HitBody"
const PATH_LOCAL_CONTROLLER: NodePath = ^"Core/Controller"
const PATH_ARMS: NodePath = ^"Arms"

const OCCLUSION_CHECK_TICKS: int = 24
const OCCLUSION_DB_PENALTY: float = -8.0
const OCCLUSION_CUTOFF_HZ: float = 800.0

const CAPSULE_HEIGHT: float = 1.8
const CAPSULE_RADIUS: float = 0.3
const CAPSULE_CHEST_Y: float = 1.3
const CAPSULE_WEAPON_MOUNT_NAME: StringName = &"WeaponMount"

# RigManager.UpdateRig normally drives arm sleeve/glove materials from the
# local player's torso/hand equipment slots. On a peer we don't have that
# state, so apply the same defaults RigManager falls back to.
const FPS_DEFAULT_SLEEVES_PATH: String = "res://Items/Clothing/Jacket_M62/Files/MT_Jacket_M62_Sleeves.tres"
const FPS_DEFAULT_GLOVES_PATH: String = "res://Items/Clothing/Gloves_Leather/Files/MT_Gloves_Leather.tres"

# Holster tween: drop arms below chest before freeing rig, raise from below
# when drawing fresh. Vanilla local game has no draw/holster animation
# (PlayEquip is audio-only); peer adds visual feedback so the rig doesn't
# pop in/out of existence on weapon swap.
const HOLSTER_DROP_Y: float = -0.6
const HOLSTER_TWEEN_SECS: float = 0.2


var targetPosition: Vector3 = Vector3.ZERO
var targetRotationY: float = 0.0
var targetRotationX: float = 0.0
var moveFlags: int = 0
var displayName: String = "":
    set(value):
        displayName = value
        _lastRenderedHealth = -999
var isDead: bool = false
var _lastRenderedHealth: int = -999
var _moveFlag: Dictionary = {}
# set_appearance fires twice on spawn; cache avoids redundant .tres parses.
var _materialCache: Dictionary[String, Material] = {}

var audioPlayer: AudioStreamPlayer3D = null
var occlusionRay: PhysicsRayQueryParameters3D = null
var isOccluded: bool = false
var occludedBusName: StringName = &""
var occludedBusIdx: int = -1

var meshNode: MeshInstance3D = null
var weaponMount: Marker3D = null
var activeWeapon: Node3D = null
var activeMuzzle: Node3D = null
# AnimationTree harvested from the attached FPS weapon rig (per-weapon).
# Local WeaponRig drives state machine transitions via brief condition
# pulses (Reload=true on keypress, false on the same tick), which are too
# fast to network sync reliably; instead we broadcast the playback's
# current state name and travel() to it on the peer.
var weaponAnimTree: AnimationTree = null
# Last playback state name applied via RPC; replayed on weapon swap so a
# peer arriving mid-reload still ends up at the right pose.
var _lastAnimState: String = ""
# Active holster/draw tween — kill on weapon swap so cancelled tween
# doesn't leave a freshly-drawn rig stuck at HOLSTER_DROP_Y.
var _weaponMountTween: Tween = null
# Mount Y offset on initial spawn — captured from _spawn_capsule_rig so
# the holster tween knows what "raised" position to interpolate back to.
var _weaponMountRestY: float = 0.0
# StringName so _apply_attachments pointer-compares vs Attachments child names.
var _activeAttachments: Array[StringName] = []


@onready var nameLabel: Label3D = $NameLabel


func _ready() -> void:
    _moveFlag = CoopManager.PlayerStateScript.MoveFlag
    nameLabel.text = displayName
    targetPosition = global_position

    audioPlayer = AudioStreamPlayer3D.new()
    audioPlayer.max_distance = 50.0
    audioPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
    add_child(audioPlayer)

    _ensure_occluded_bus()
    _spawn_capsule_rig()
    _create_collision_body()
    add_to_group(&"CoopRemote")

    var defaults: Dictionary = CoopManager.appearance.get_defaults()
    set_appearance(defaults.body, defaults.material)


func _spawn_capsule_rig() -> void:
    var meshInst: MeshInstance3D = MeshInstance3D.new()
    var capsule: CapsuleMesh = CapsuleMesh.new()
    capsule.radius = CAPSULE_RADIUS
    capsule.height = CAPSULE_HEIGHT
    meshInst.mesh = capsule
    meshInst.position.y = CAPSULE_HEIGHT * 0.5
    add_child(meshInst)
    meshNode = meshInst

    # Marker3D ≈ BoneAttachment3D for a skeletonless rig — set_active_weapon
    # parents the FPS weapon rig here. The FPS rig is authored for a Camera3D
    # parent looking down -Z (Godot's default forward) with arms+gun in the
    # camera's view; mounted directly under the capsule the rig presents
    # back-to-front. Rotate 180° around Y so the rig's "in front of camera"
    # axis aligns with the capsule's forward direction (-Z).
    var mount: Marker3D = Marker3D.new()
    mount.name = CAPSULE_WEAPON_MOUNT_NAME
    mount.position = Vector3(0.25, CAPSULE_CHEST_Y, -0.35)
    mount.rotation.y = PI
    add_child(mount)
    weaponMount = mount
    _weaponMountRestY = mount.position.y


func set_appearance(body: String, materialPath: String) -> void:
    if !CoopManager.appearance.is_valid({"body": body, "material": materialPath}):
        return
    if !is_instance_valid(meshNode):
        return
    var mat: Material = _load_material(materialPath)
    if mat == null:
        return
    var surfaceCount: int = meshNode.mesh.get_surface_count() if meshNode.mesh != null else 0
    for i: int in surfaceCount:
        meshNode.set_surface_override_material(i, mat)


func _load_material(path: String) -> Material:
    var cached: Material = null
    if _materialCache.has(path):
        cached = _materialCache[path]
    if cached != null:
        return cached
    if !ResourceLoader.exists(path):
        return null
    var mat: Material = load(path) as Material
    if mat != null:
        _materialCache[path] = mat
    return mat


func set_active_weapon(weaponName: String) -> void:
    if !is_instance_valid(weaponMount):
        return

    if _weaponMountTween != null && _weaponMountTween.is_valid():
        _weaponMountTween.kill()
    _weaponMountTween = null

    var hasOldRig: bool = is_instance_valid(activeWeapon)
    var wantsRig: bool = !weaponName.is_empty() && _is_valid_weapon_name(weaponName)

    if hasOldRig && !wantsRig:
        # Holster: tween rig down then free.
        _holster_tween_down()
        return

    # Drawing or swapping — clear current rig immediately.
    if hasOldRig:
        activeWeapon.queue_free()
    activeWeapon = null
    activeMuzzle = null
    weaponAnimTree = null

    if !wantsRig:
        weaponMount.position.y = _weaponMountRestY
        return

    var startFromHolster: bool = !hasOldRig
    if startFromHolster:
        weaponMount.position.y = _weaponMountRestY + HOLSTER_DROP_Y
    else:
        weaponMount.position.y = _weaponMountRestY
    _attach_fps_rig(weaponMount, weaponName)
    _apply_attachments()
    if startFromHolster:
        _holster_tween_up()


func _holster_tween_down() -> void:
    var rig: Node3D = activeWeapon
    activeMuzzle = null
    weaponAnimTree = null
    activeWeapon = null
    var startY: float = weaponMount.position.y
    var tween: Tween = create_tween()
    tween.tween_property(weaponMount, ^"position:y", _weaponMountRestY + HOLSTER_DROP_Y, HOLSTER_TWEEN_SECS).from(startY)
    tween.tween_callback(_on_holster_complete.bind(rig))
    _weaponMountTween = tween


func _on_holster_complete(rig: Node) -> void:
    if is_instance_valid(rig):
        rig.queue_free()
    if is_instance_valid(weaponMount):
        weaponMount.position.y = _weaponMountRestY


func _holster_tween_up() -> void:
    var tween: Tween = create_tween()
    tween.tween_property(weaponMount, ^"position:y", _weaponMountRestY, HOLSTER_TWEEN_SECS)
    _weaponMountTween = tween


## Loads the FPS weapon rig (full animations), strips its script + UI/camera
## coupling, forces VisualInstance3D layers from FPS-only (layer 2) to default
## world (layer 1) so peers' world cameras render it, applies default sleeve/
## glove materials to the arm mesh.
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
    # WeaponRig.gd is the rig root script, but Handling/Sway/Noise/Tilt/Impulse/
    # Recoil children all have their own scripts that read the LOCAL viewer's
    # gameData (mouse delta, aim state, scope flags) and rewrite their own
    # transforms every frame. On a peer those drives are wrong: the rig
    # ends up drifting around the world following the viewer's mouse instead
    # of staying parented to the capsule mount. Strip every script in the
    # subtree before adding to the mount.
    _strip_scripts_recursive(rig)
    _strip_rig_recursive(rig)
    _strip_fps_rig_recursive(rig)
    _force_world_layer_recursive(rig)
    if rig is Node3D:
        (rig as Node3D).transform = Transform3D.IDENTITY
    mount.add_child(rig)
    activeWeapon = rig as Node3D
    activeMuzzle = rig.get_node_or_null(PATH_MUZZLE) as Node3D
    _apply_default_arm_materials(rig)
    var rigTree: AnimationTree = _find_tree_in_subtree(rig)
    if rigTree != null:
        # WeaponRig._ready (which we strip) normally activates the tree. Force
        # it on here so the state machine evaluates and travel() works.
        rigTree.active = true
        weaponAnimTree = rigTree
        # Diag: confirms the tree actually advances clips after travel(). If
        # this signal never fires after a successful travel(), the tree is
        # silently failing (likely AnimationPlayer.root_node mis-binding or
        # missing AnimationLibrary).
        if !rigTree.animation_started.is_connected(_on_peer_anim_started):
            rigTree.animation_started.connect(_on_peer_anim_started)
        if !_lastAnimState.is_empty():
            _apply_anim_state(_lastAnimState)


func _on_peer_anim_started(clipName: StringName) -> void:
    if !is_instance_valid(CoopManager):
        return
    CoopManager._log("[remote_player] peer=%s anim_started clip=%s" % [str(displayName), str(clipName)])


## FPS rigs ship with per-link scripts (Handling/Sway/Noise/Tilt/Impulse/
## Recoil + WeaponRig at the root) that read gameData every frame and adjust
## their own transforms. On a peer those reads pull the local viewer's input
## state, dragging the rig away from the capsule mount. Recursively null
## every script in the subtree so the rig becomes a static node tree —
## animation drives only what the AnimationPlayer authored.
func _strip_scripts_recursive(node: Node) -> void:
    node.set_script(null)
    for child: Node in node.get_children():
        _strip_scripts_recursive(child)


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


func _find_tree_in_subtree(root: Node) -> AnimationTree:
    if root is AnimationTree:
        return root as AnimationTree
    for child: Node in root.get_children():
        var found: AnimationTree = _find_tree_in_subtree(child)
        if found != null:
            return found
    return null


## Mirrors the local player's AnimationTree playback state onto this peer's
## attached weapon rig. [param stateName] is the name of the currently-active
## state-machine node (e.g. [code]"Reload"[/code], [code]"Inspect_Front"[/code],
## [code]"Idle"[/code]) — calling [code]playback.travel(stateName)[/code]
## transitions to it through the rig's authored transition graph.
func set_active_anim_state(stateName: String) -> void:
    _lastAnimState = stateName
    _apply_anim_state(stateName)


func _apply_anim_state(stateName: String) -> void:
    if !is_instance_valid(weaponAnimTree):
        return
    if stateName.is_empty():
        return
    var playback: Variant = weaponAnimTree.get(&"parameters/playback")
    if playback == null:
        return
    if String(playback.get_current_node()) == stateName:
        return
    playback.travel(stateName)


## Equipment-sync entry for attachments. Mirrors [method Pickup._ready]'s
## attachment reveal: walks the active weapon's [code]Attachments[/code] child,
## hides every attachment node, then [code].show()[/code]s the ones whose
## [code]name[/code] matches the incoming [StringName] list.
func set_active_attachments(names: Array[StringName]) -> void:
    _activeAttachments = names
    _apply_attachments()


func _apply_attachments() -> void:
    if !is_instance_valid(activeWeapon):
        return
    var attachmentsRoot: Node = activeWeapon.get_node_or_null(^"Attachments")
    if attachmentsRoot == null:
        return
    for child: Node in attachmentsRoot.get_children():
        if child is Node3D:
            (child as Node3D).visible = false
    for stem: StringName in _activeAttachments:
        var node: Node = attachmentsRoot.get_node_or_null(NodePath(stem))
        if node is Node3D:
            (node as Node3D).visible = true
            # Update activeMuzzle so fire-event flashes use the equipped muzzle
            # instead of the bare-barrel Muzzle node.
            var candidate: Node3D = node.get_node_or_null(PATH_MUZZLE) as Node3D
            if candidate != null:
                activeMuzzle = candidate


## Allowlist for weapon file names — prevents path traversal / arbitrary load.
func _is_valid_weapon_name(weapon_name: String) -> bool:
    if weapon_name.length() > 32:
        return false
    for i: int in weapon_name.length():
        var c: int = weapon_name.unicode_at(i)
        var ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
        if !ok:
            return false
    return true


func _create_collision_body() -> void:
    var staticBody: StaticBody3D = StaticBody3D.new()
    staticBody.name = "HitBody"
    staticBody.collision_layer = COOP_HIT_LAYER
    staticBody.collision_mask = 0
    staticBody.add_to_group(&"CoopRemote")
    if has_meta(&"peer_id"):
        staticBody.set_meta(&"peer_id", get_meta(&"peer_id"))

    var capsule: CapsuleShape3D = CapsuleShape3D.new()
    capsule.radius = 0.3
    capsule.height = 1.8
    var shape: CollisionShape3D = CollisionShape3D.new()
    shape.shape = capsule
    shape.position.y = 0.9

    staticBody.add_child(shape)
    add_child(staticBody)


## Creates the shared "CoopOccluded" bus lazily — bus indices shift at runtime
## so name-based lookup beats caching the index across map loads.
func _ensure_occluded_bus() -> void:
    occludedBusName = &"CoopOccluded"
    var idx: int = AudioServer.get_bus_index(occludedBusName)
    if idx >= 0:
        occludedBusIdx = idx
        return
    AudioServer.add_bus()
    occludedBusIdx = AudioServer.bus_count - 1
    AudioServer.set_bus_name(occludedBusIdx, occludedBusName)
    AudioServer.set_bus_send(occludedBusIdx, &"Master")
    AudioServer.set_bus_volume_db(occludedBusIdx, OCCLUSION_DB_PENALTY)
    var lpf: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
    lpf.cutoff_hz = OCCLUSION_CUTOFF_HZ
    AudioServer.add_bus_effect(occludedBusIdx, lpf)


func _update_occlusion() -> void:
    if !is_instance_valid(audioPlayer) || occludedBusIdx < 0:
        return
    var cam: Camera3D = get_viewport().get_camera_3d()
    if cam == null:
        return

    var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    var from: Vector3 = cam.global_position
    var to: Vector3 = global_position + Vector3(0, 1.0, 0)

    if occlusionRay == null:
        occlusionRay = PhysicsRayQueryParameters3D.create(from, to)
        occlusionRay.collision_mask = 1
        # Exclude the local player so the ray doesn't immediately self-hit.
        var controller: Node = get_tree().current_scene.get_node_or_null(PATH_LOCAL_CONTROLLER)
        if controller is PhysicsBody3D:
            occlusionRay.exclude = [controller.get_rid()]
    else:
        occlusionRay.from = from
        occlusionRay.to = to

    var result: Dictionary = space.intersect_ray(occlusionRay)
    var nowOccluded: bool = !result.is_empty()

    if nowOccluded != isOccluded:
        isOccluded = nowOccluded
        audioPlayer.bus = occludedBusName if isOccluded else &"Master"


func die() -> void:
    isDead = true
    set_meta(&"is_dead", true)
    set_meta(&"health", 0)
    nameLabel.text = "%s [DEAD]" % displayName
    _lastRenderedHealth = 0
    var hitBody: Node = get_node_or_null(PATH_HITBODY)
    if hitBody != null:
        hitBody.collision_layer = 0
        hitBody.remove_from_group(&"CoopRemote")


func _physics_process(_delta: float) -> void:
    if !is_instance_valid(CoopManager) || isDead:
        return
    global_position = targetPosition
    rotation.y = targetRotationY

    if Engine.get_physics_frames() % OCCLUSION_CHECK_TICKS == 0:
        _update_occlusion()

    var health: int = get_meta(&"health", -1)
    if health != _lastRenderedHealth:
        _lastRenderedHealth = health
        if health >= 0:
            nameLabel.text = "%s [%d%%]" % [displayName, health]
        else:
            nameLabel.text = displayName


func update_state(pos: Vector3, rot: Vector3, flags: int) -> void:
    targetPosition = pos
    targetRotationY = rot.x
    targetRotationX = rot.y
    moveFlags = flags


## Single source of truth — callers read state via predicate to avoid drift
## between `moveFlags` and mirror bool vars.
func has_flag(flag: int) -> bool:
    return (moveFlags & flag) != 0


func play_remote_audio(audioPath: String) -> void:
    if !is_instance_valid(audioPlayer):
        return
    if !audioPath.begins_with("res://Resources/") && !audioPath.begins_with("res://Audio/"):
        return
    var audioEvent: Resource = load(audioPath)
    if audioEvent == null || !audioEvent.has_method(&"get"):
        return
    if audioEvent.audioClips.is_empty():
        return
    audioPlayer.bus = occludedBusName if isOccluded && occludedBusIdx >= 0 else &"Master"
    audioPlayer.stream = audioEvent.audioClips.pick_random()
    audioPlayer.volume_db = audioEvent.volume
    audioPlayer.pitch_scale = randf_range(0.9, 1.0) if audioEvent.randomPitch else 1.0
    audioPlayer.play()


var hitDefaultScene: PackedScene = preload("res://Effects/Hit_Default.tscn")
var hitKnifeScene: PackedScene = preload("res://Effects/Hit_Knife.tscn")


func spawn_bullet_impact(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var hit: Node3D = hitDefaultScene.instantiate()
    scene.add_child(hit)
    hit.global_position = hitPoint

    if hitNormal == Vector3(0, 1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    elif hitNormal == Vector3(0, -1, 0):
        hit.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    else:
        hit.look_at(hitPoint + hitNormal, Vector3.DOWN)
    hit.global_rotation.z = randf_range(-360, 360)

    hit.Emit()
    hit.PlayHit(hitSurface)


func play_knife_attack(isSlash: bool) -> void:
    if !is_instance_valid(CoopManager):
        return
    var audioEvent: AudioEvent = CoopManager.audioLibrary.knifeSlash if isSlash else CoopManager.audioLibrary.knifeStab
    if audioEvent == null || audioEvent.audioClips.is_empty():
        return
    if !is_instance_valid(audioPlayer):
        return
    audioPlayer.stream = audioEvent.audioClips.pick_random()
    audioPlayer.volume_db = audioEvent.volume
    audioPlayer.play()


func spawn_knife_impact(hitPoint: Vector3, hitNormal: Vector3, hitSurface: String, isFlesh: bool, attackId: int) -> void:
    var scene: Node = get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var decal: Node3D = hitKnifeScene.instantiate()
    scene.add_child(decal)
    decal.global_position = hitPoint

    if hitNormal == Vector3(0, 1, 0):
        decal.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    elif hitNormal == Vector3(0, -1, 0):
        decal.look_at(hitPoint + hitNormal, Vector3.RIGHT)
    else:
        decal.look_at(hitPoint + hitNormal, Vector3.DOWN)

    # Angles match KnifeRig.KnifeDecal per combo index.
    match attackId:
        1: decal.global_rotation_degrees.z = 30.0
        2: decal.global_rotation_degrees.z = 10.0
        3: decal.global_rotation_degrees.z = -10.0
        4: decal.global_rotation_degrees.z = -30.0
        5: decal.global_rotation_degrees.z = 15.0
        6: decal.global_rotation_degrees.z = 0.0
        7: decal.global_rotation_degrees.z = -30.0
        8: decal.global_rotation_degrees.z = 45.0

    if isFlesh:
        decal.PlayKnifeHitFlesh(attackId)
    else:
        decal.PlayKnifeHit(hitSurface)


func play_fire_event(fireAudio: String, tailAudio: String, _showFlash: bool) -> void:
    play_remote_audio(fireAudio)

    # Tail audio on its own player so it doesn't cut the fire sound.
    if !tailAudio.is_empty():
        var tailEvent: Resource = load(tailAudio)
        if tailEvent != null && !tailEvent.audioClips.is_empty():
            var tailPlayer: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
            tailPlayer.max_distance = 100.0
            tailPlayer.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
            add_child(tailPlayer)
            tailPlayer.stream = tailEvent.audioClips.pick_random()
            tailPlayer.volume_db = tailEvent.volume
            if isOccluded && occludedBusIdx >= 0:
                tailPlayer.bus = occludedBusName
            tailPlayer.play()
            tailPlayer.finished.connect(tailPlayer.queue_free)
