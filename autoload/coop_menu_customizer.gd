## Customizes the vanilla main menu — rewires the New/Load buttons to
## Singleplayer/Multiplayer and builds a co-op submenu (Host/Browse/Direct Join).
## Lives as a child node of CoopManager so signals can bind to its methods directly.
extends Node


const PATH_MENU_MAIN: NodePath = ^"Main"
const PATH_MENU_MODES: NodePath = ^"Modes"
const PATH_MENU_SUBMENU: NodePath = ^"CoopMPSubmenu"
const PATH_MENU_BTN_NEW: NodePath = ^"Main/Buttons/New"
const PATH_MENU_BTN_LOAD: NodePath = ^"Main/Buttons/Load"


var _cm: Node


func init_manager(cm: Node) -> void:
    _cm = cm


## Called from CoopManager.on_scene_changed — only customizes the Menu scene.
func maybe_customize(scene: Node) -> void:
    var scenePath: String = scene.scene_file_path if is_instance_valid(scene) else ""
    if scenePath != "res://Scenes/Menu.tscn":
        return
    _customize(scene)
    if !_cm.is_session_active() && !_cm._wasInCoop:
        _cm.mirror_user_to_solo()
    _cm._wasInCoop = false


func _customize(menu: Node) -> void:
    if menu.has_meta(&"coop_customized"):
        return
    menu.set_meta(&"coop_customized", true)

    var newButton: Button = menu.get_node_or_null(PATH_MENU_BTN_NEW)
    var loadButton: Button = menu.get_node_or_null(PATH_MENU_BTN_LOAD)
    if newButton == null || loadButton == null:
        _cm._log("[menu] customize aborted: buttons missing")
        return

    newButton.text = "Singleplayer"
    loadButton.text = "Multiplayer"
    loadButton.disabled = false

    var newSignalCallable: Callable = Callable(menu, "_on_new_pressed")
    var loadSignalCallable: Callable = Callable(menu, "_on_load_pressed")
    if newButton.pressed.is_connected(newSignalCallable):
        newButton.pressed.disconnect(newSignalCallable)
    if loadButton.pressed.is_connected(loadSignalCallable):
        loadButton.pressed.disconnect(loadSignalCallable)

    newButton.pressed.connect(_on_singleplayer_pressed.bind(menu))
    loadButton.pressed.connect(_on_multiplayer_pressed.bind(menu))

    _build_submenu(menu)
    _cm._log("[menu] customized: Singleplayer/Multiplayer active")


func _on_singleplayer_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    # Guard against wipe_user_saves() destroying active session state.
    if _cm.is_session_active():
        _cm._log("[menu] Singleplayer pressed during active session — ignored")
        return
    _cm.wipe_user_saves()
    _cm.mirror_solo_to_user()
    var main: Node = menu.get_node_or_null(PATH_MENU_MAIN)
    var modes: Node = menu.get_node_or_null(PATH_MENU_MODES)
    if main != null:
        main.hide()
    if modes != null:
        modes.show()


func _on_multiplayer_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var main: Node = menu.get_node_or_null(PATH_MENU_MAIN)
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    if main != null:
        main.hide()
    if submenu != null:
        submenu.show()


func _build_submenu(menu: Node) -> void:
    if menu.get_node_or_null(PATH_MENU_SUBMENU) != null:
        return

    var gameTheme: Theme = load("res://UI/Themes/Theme.tres")

    var wrapper: Control = Control.new()
    wrapper.name = "CoopMPSubmenu"
    wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    wrapper.mouse_filter = Control.MOUSE_FILTER_STOP
    if gameTheme != null:
        wrapper.theme = gameTheme
    menu.add_child(wrapper)
    wrapper.hide()

    var outer: VBoxContainer = VBoxContainer.new()
    outer.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    outer.grow_horizontal = Control.GROW_DIRECTION_BOTH
    outer.grow_vertical = Control.GROW_DIRECTION_BOTH
    outer.custom_minimum_size = Vector2(560, 0)
    outer.add_theme_constant_override(&"separation", 4)
    wrapper.add_child(outer)

    var header: Label = Label.new()
    header.text = "Multiplayer"
    header.add_theme_font_size_override(&"font_size", 20)
    header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(header)

    var subheader: Label = Label.new()
    subheader.text = "Co-op mode"
    subheader.modulate = Color(1, 1, 1, 0.5)
    subheader.add_theme_font_size_override(&"font_size", 12)
    subheader.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(subheader)

    var topSpacer: Control = Control.new()
    topSpacer.custom_minimum_size = Vector2(0, 16)
    outer.add_child(topSpacer)

    var btnGrid: HBoxContainer = HBoxContainer.new()
    btnGrid.add_theme_constant_override(&"separation", 8)
    outer.add_child(btnGrid)

    var hostCol: VBoxContainer = VBoxContainer.new()
    hostCol.add_theme_constant_override(&"separation", 4)
    hostCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btnGrid.add_child(hostCol)

    var hostBtn: Button = _row_button("Host (Steam)")
    hostBtn.name = "HostBtn"
    hostBtn.disabled = true
    hostBtn.pressed.connect(_on_host_pressed.bind(menu))
    hostCol.add_child(hostBtn)

    var hostIpBtn: Button = _row_button("Host (IP)")
    hostIpBtn.pressed.connect(_on_host_ip_pressed.bind(menu))
    hostCol.add_child(hostIpBtn)

    var joinCol: VBoxContainer = VBoxContainer.new()
    joinCol.add_theme_constant_override(&"separation", 4)
    joinCol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btnGrid.add_child(joinCol)

    var browseBtn: Button = _row_button("Browse Lobbies")
    browseBtn.name = "BrowseBtn"
    browseBtn.disabled = true
    browseBtn.pressed.connect(_on_browse_pressed.bind(menu))
    joinCol.add_child(browseBtn)

    var joinBtn: Button = _row_button("Direct Join")
    joinBtn.pressed.connect(_on_show_direct_join.bind(menu))
    joinCol.add_child(joinBtn)

    var footerSpacer: Control = Control.new()
    footerSpacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
    outer.add_child(footerSpacer)

    var logsBtn: Button = _submenu_button("Open Logs Folder")
    logsBtn.pressed.connect(_on_logs_pressed)
    outer.add_child(logsBtn)

    var returnBtn: Button = _submenu_button("← Return")
    returnBtn.pressed.connect(_on_back_pressed.bind(menu))
    outer.add_child(returnBtn)


func _submenu_button(btnText: String) -> Button:
    var btn: Button = Button.new()
    btn.text = btnText
    btn.custom_minimum_size = Vector2(256, 40)
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    return btn


func _row_button(btnText: String) -> Button:
    var btn: Button = Button.new()
    btn.text = btnText
    btn.custom_minimum_size = Vector2(0, 40)
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return btn


func _on_host_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    _cm._pendingHostUseSteam = true
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    if submenu != null:
        submenu.hide()
    if is_instance_valid(_cm.coopUI):
        _cm.coopUI.show_lobby(true)


func _on_host_ip_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    _cm._pendingHostUseSteam = false
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    if submenu != null:
        submenu.hide()
    if is_instance_valid(_cm.coopUI):
        _cm.coopUI.show_lobby(false)


func _on_show_direct_join(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    if submenu != null:
        submenu.hide()
    if is_instance_valid(_cm.coopUI):
        _cm.coopUI.show_direct_join_dialog()


func _on_browse_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    if submenu != null:
        submenu.hide()
    if is_instance_valid(_cm.coopUI):
        _cm.coopUI.show_lobby_browser()


func _on_logs_pressed() -> void:
    _cm.collect_logs()


func _on_back_pressed(menu: Node) -> void:
    if menu.has_method(&"PlayClick"):
        menu.PlayClick()
    var submenu: Node = menu.get_node_or_null(PATH_MENU_SUBMENU)
    var main: Node = menu.get_node_or_null(PATH_MENU_MAIN)
    if submenu != null:
        submenu.hide()
    if main != null:
        main.show()
