## Character-creation picker. Two-step selection: model then texture variant.
## Shown when hosting a new world or when a client joins without a local save.
## Persists choice via coop_manager.
extends Control


const SELECTED_COLOR: Color = Color(1, 1, 1)
const UNSELECTED_COLOR: Color = Color(1, 1, 1, 0.5)
const PREVIEW_SIZE: Vector2i = Vector2i(416, 416)
const IDLE_ANIM: StringName = &"Rifle_Idle"
const GAME_THEME_PATH: String = "res://UI/Themes/Theme.tres"
const PREVIEW_RIFLE_NAME: String = "AK-12"

var _cm: Node = null
var _onConfirm: Callable = Callable()
var _onCancel: Callable = Callable()

var _byBody: Dictionary = {}
var _bodyOrder: Array[String] = []

var _selectedBody: String = ""
var _selectedMaterial: String = ""

var _modelButtons: Dictionary[String, Button] = {}
var _textureButtons: Array[Button] = []
var _textureRow: HBoxContainer = null

var _previewViewport: SubViewport = null
## Currently-loaded preview body Node3D (subtree of the selected AI rig).
## Replaced when [member _selectedBody] changes — each rig carries its own
## skeleton so we can't share meshes across bodies.
var _previewBody: Node3D = null
var _previewBodyName: String = ""
var _previewMesh: MeshInstance3D = null


func init(cm: Node, onConfirm: Callable, onCancel: Callable = Callable()) -> void:
    _cm = cm
    _onConfirm = onConfirm
    _onCancel = onCancel
    _group_options()
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    # Pick up the base-game theme so fonts + button styles match host/lobby
    # dialogs. Without this, buttons render with Godot's default grey theme.
    var gameTheme: Theme = load(GAME_THEME_PATH) as Theme
    if gameTheme != null:
        theme = gameTheme
    _build_ui()
    var current: Dictionary = _cm.load_local_appearance()
    _selectedBody = current.get("body", _bodyOrder[0])
    _selectedMaterial = current.get("material", "")
    if !_byBody.has(_selectedBody):
        _selectedBody = _bodyOrder[0]
    if !_material_belongs_to(_selectedBody, _selectedMaterial):
        _selectedMaterial = _byBody[_selectedBody][0].material
    _rebuild_texture_row()
    _refresh()


func _group_options() -> void:
    for opt: Dictionary in _cm.AppearanceScript.OPTIONS:
        var body: String = opt.body
        if !_byBody.has(body):
            _byBody[body] = []
            _bodyOrder.append(body)
        var label: String = opt.name
        if label.begins_with(body + " "):
            label = label.substr(body.length() + 1)
        elif label == body:
            label = "Default"
        _byBody[body].append({"name": label, "material": opt.material})


func _material_belongs_to(body: String, mat: String) -> bool:
    if !_byBody.has(body):
        return false
    for entry: Dictionary in _byBody[body]:
        if entry.material == mat:
            return true
    return false


func _build_ui() -> void:
    var outer: VBoxContainer = VBoxContainer.new()
    outer.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    outer.grow_horizontal = Control.GROW_DIRECTION_BOTH
    outer.grow_vertical = Control.GROW_DIRECTION_BOTH
    outer.custom_minimum_size = Vector2(560, 0)
    outer.add_theme_constant_override("separation", 4)
    add_child(outer)

    var header: Label = Label.new()
    header.text = "Choose Your Character"
    header.add_theme_font_size_override("font_size", 20)
    header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(header)

    var subheader: Label = Label.new()
    subheader.text = "Pick a model — you can't change this later."
    subheader.modulate = Color(1, 1, 1, 0.5)
    subheader.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subheader.add_theme_font_size_override("font_size", 12)
    outer.add_child(subheader)

    var topSpacer: Control = Control.new()
    topSpacer.custom_minimum_size = Vector2(0, 8)
    outer.add_child(topSpacer)

    _build_preview(outer)

    outer.add_child(_make_section_header("Model"))
    var modelRow: HBoxContainer = HBoxContainer.new()
    modelRow.add_theme_constant_override("separation", 8)
    modelRow.alignment = BoxContainer.ALIGNMENT_CENTER
    outer.add_child(modelRow)
    for body: String in _bodyOrder:
        var btn: Button = _make_option_button(body)
        btn.pressed.connect(_on_model_pressed.bind(body))
        modelRow.add_child(btn)
        _modelButtons[body] = btn

    outer.add_child(_make_section_header("Texture"))
    _textureRow = HBoxContainer.new()
    _textureRow.add_theme_constant_override("separation", 8)
    _textureRow.alignment = BoxContainer.ALIGNMENT_CENTER
    outer.add_child(_textureRow)

    var bottomSpacer: Control = Control.new()
    bottomSpacer.custom_minimum_size = Vector2(0, 16)
    outer.add_child(bottomSpacer)

    var buttonRow: HBoxContainer = HBoxContainer.new()
    buttonRow.add_theme_constant_override("separation", 16)
    buttonRow.alignment = BoxContainer.ALIGNMENT_CENTER
    outer.add_child(buttonRow)

    var returnBtn: Button = Button.new()
    returnBtn.text = "← Return"
    returnBtn.custom_minimum_size = Vector2(256, 40)
    returnBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    returnBtn.pressed.connect(_on_cancel_pressed)
    buttonRow.add_child(returnBtn)

    var confirmBtn: Button = Button.new()
    confirmBtn.text = "Confirm"
    confirmBtn.custom_minimum_size = Vector2(256, 40)
    confirmBtn.mouse_filter = Control.MOUSE_FILTER_STOP
    confirmBtn.pressed.connect(_on_confirm_pressed)
    buttonRow.add_child(confirmBtn)


func _make_section_header(text: String) -> Label:
    var label: Label = Label.new()
    label.text = text
    label.modulate = Color(1, 1, 1, 0.5)
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.add_theme_font_size_override("font_size", 12)
    return label


func _make_option_button(text: String) -> Button:
    var btn: Button = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(120, 36)
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    return btn


func _build_preview(parent: Container) -> void:
    var container: SubViewportContainer = SubViewportContainer.new()
    container.custom_minimum_size = Vector2(PREVIEW_SIZE)
    container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    container.stretch = true
    container.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(container)

    _previewViewport = SubViewport.new()
    _previewViewport.size = PREVIEW_SIZE
    _previewViewport.handle_input_locally = false
    _previewViewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE

    # Assign World3D + Environment BEFORE add_child so the viewport's scenario
    # is initialized from our world rather than auto-generated then swapped
    # (which triggers scenario_remove_viewport_visibility_mask null errors).
    var world_3d: World3D = World3D.new()
    var env: Environment = Environment.new()
    env.background_mode = Environment.BG_CLEAR_COLOR
    env.ambient_light_source = Environment.AMBIENT_SOURCE_BG
    env.ambient_light_color = Color.BLACK
    world_3d.environment = env
    _previewViewport.world_3d = world_3d
    _previewViewport.own_world_3d = true

    container.add_child(_previewViewport)

    # Body load is deferred to _apply_preview — selected body may differ from
    # default and per-rig skeletons can't be swapped after instantiation.

    # Default forward is -Z; placing the camera at +Z frames the model with
    # no look_at needed. Height = mid-body so the rig sits centered vertically
    # in the viewport at the default 75° FOV.
    var cam: Camera3D = Camera3D.new()
    cam.position = Vector3(0, 1.3, 1.3)
    cam.rotation_degrees = Vector3(-16.0, 0.0, 0.0)
    _previewViewport.add_child(cam)

    var light: DirectionalLight3D = DirectionalLight3D.new()
    light.rotate_x(deg_to_rad(-35))
    light.rotate_y(deg_to_rad(30))
    light.light_energy = 1.2
    _previewViewport.add_child(light)


## Attaches the AI's bundled rifle (if present) to the Weapons BoneAttachment
## so the Rifle_Idle pose reads correctly (empty hands look broken in that
## stance). Falls through silently for AI rigs whose bundle lacks the named
## weapon — preview just shows empty hands.
func _attach_preview_rifle(skel: Skeleton3D) -> void:
    var weapons: Node = skel.get_node_or_null("Weapons")
    if weapons == null:
        return
    var baked: Node3D = weapons.get_node_or_null(PREVIEW_RIFLE_NAME) as Node3D
    if baked != null:
        baked.visible = true


## Loads the AI scene for [param body], strips the AI script + sensors so it's
## inert, and reparents the visual subtree into the preview viewport. Mirrors
## remote_player._load_body_rig but trimmed to what the picker needs (no
## Collision/Flash, no spine pitch override).
## Lazy-loaded once; gives the picker access to BODY_SCENES without forcing
## a circular preload at parse time.
const _RemotePlayerScript: GDScript = preload("res://mod/presentation/remote_player.gd")


func _instantiate_body_rig(body: String) -> Node3D:
    if !_RemotePlayerScript.BODY_SCENES.has(body):
        return null
    var path: String = _RemotePlayerScript.BODY_SCENES[body]
    if path.is_empty():
        return null
    var packed: PackedScene = load(path) as PackedScene
    if packed == null:
        return null
    var rigRoot: Node = packed.instantiate()
    if rigRoot == null:
        return null
    rigRoot.set_script(null)
    var bodyContainer: Node3D = rigRoot.get_node_or_null(body) as Node3D
    if bodyContainer == null:
        rigRoot.queue_free()
        return null
    rigRoot.remove_child(bodyContainer)
    rigRoot.queue_free()
    # Clear owner ref recursively — bodyContainer + descendants still point at
    # the freed scene root, triggering the "owner inconsistent" warning when
    # add_child happens against the SubViewport.
    _clear_owners(bodyContainer)
    return bodyContainer


static func _clear_owners(node: Node) -> void:
    node.owner = null
    for child: Node in node.get_children():
        _clear_owners(child)


func _on_model_pressed(body: String) -> void:
    if _selectedBody == body:
        return
    _selectedBody = body
    _selectedMaterial = _byBody[body][0].material
    _rebuild_texture_row()
    _refresh()


func _on_texture_pressed(mat: String) -> void:
    _selectedMaterial = mat
    _refresh()


func _rebuild_texture_row() -> void:
    for old: Button in _textureButtons:
        if is_instance_valid(old):
            old.queue_free()
    _textureButtons.clear()
    var entries: Array = _byBody[_selectedBody]
    for entry: Dictionary in entries:
        var btn: Button = _make_option_button(entry.name)
        btn.pressed.connect(_on_texture_pressed.bind(entry.material))
        _textureRow.add_child(btn)
        _textureButtons.append(btn)


func _refresh() -> void:
    for body: String in _modelButtons:
        _modelButtons[body].modulate = SELECTED_COLOR if body == _selectedBody else UNSELECTED_COLOR

    var entries: Array = _byBody[_selectedBody]
    for i: int in _textureButtons.size():
        _textureButtons[i].modulate = SELECTED_COLOR if entries[i].material == _selectedMaterial else UNSELECTED_COLOR

    _apply_preview(_selectedBody, _selectedMaterial)


func _apply_preview(body: String, materialPath: String) -> void:
    if body != _previewBodyName:
        if is_instance_valid(_previewBody):
            _previewBody.queue_free()
        _previewBody = null
        _previewMesh = null
        _previewBodyName = ""
        var newBody: Node3D = _instantiate_body_rig(body)
        if newBody == null:
            return
        _previewViewport.add_child(newBody)
        _previewBody = newBody
        _previewBodyName = body
        var skel: Skeleton3D = newBody.get_node_or_null("Armature/Skeleton3D") as Skeleton3D
        if skel != null:
            _previewMesh = skel.get_node_or_null("Mesh") as MeshInstance3D
            _attach_preview_rifle(skel)
        var animPlayer: AnimationPlayer = newBody.get_node_or_null("Animations") as AnimationPlayer
        if animPlayer != null && animPlayer.has_animation(IDLE_ANIM):
            animPlayer.play(IDLE_ANIM)

    var selected: MeshInstance3D = _previewMesh
    if !is_instance_valid(selected):
        return
    var mat: Material = load(materialPath) as Material
    if mat == null:
        return
    var surfaceCount: int = selected.mesh.get_surface_count() if selected.mesh != null else 0
    for i: int in surfaceCount:
        selected.set_surface_override_material(i, mat)


func _on_confirm_pressed() -> void:
    var entry: Dictionary = {"body": _selectedBody, "material": _selectedMaterial}
    _cm.save_local_appearance(entry)
    _close()
    if _onConfirm.is_valid():
        _onConfirm.call(entry)


func _on_cancel_pressed() -> void:
    _close()
    if _onCancel.is_valid():
        _onCancel.call()


func _close() -> void:
    queue_free()
