## Hook callbacks for Loader.gd — per-world savePath (world data) + playerSavePath (character).
## Replaces patches/loader_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Loader is autoload (singleton), so per-instance state is stored as module state.
## save_mirror writes paths via Loader.set_meta(&"savePath"/&"playerSavePath"); read here.
extends RefCounted


const PATH_INTERFACE: NodePath = ^"/root/Map/Core/UI/Interface"
const PATH_RIG_MANAGER: NodePath = ^"/root/Map/Core/Camera/Manager"
const PATH_FLASHLIGHT: NodePath = ^"/root/Map/Core/Camera/Flashlight"
const PATH_NVG: NodePath = ^"/root/Map/Core/UI/NVG"
const PATH_MAP: NodePath = ^"/root/Map"

var _lib: Object = null
# Reentry guard for LoadCharacter (async timer + frame await).
var _loadCharacterInProgress: bool = false


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("loader-resetcharacter", _on_reset_character)
    lib.hook("loader-savecharacter", _on_save_character)
    lib.hook("loader-loadcharacter", _on_load_character)
    lib.hook("loader-newgame", _on_new_game)
    lib.hook("loader-saveworld", _on_save_world)
    lib.hook("loader-loadworld", _on_load_world)
    lib.hook("loader-formatsave", _on_format_save)
    lib.hook("loader-validateshelter", _on_validate_shelter)
    lib.hook("loader-saveshelter", _on_save_shelter)
    lib.hook("loader-loadshelter", _on_load_shelter)
    lib.hook("loader-checkshelterstate", _on_check_shelter_state)
    lib.hook("loader-unlockshelter", _on_unlock_shelter)
    lib.hook("loader-savetrader", _on_save_trader)
    lib.hook("loader-loadtrader", _on_load_trader)
    lib.hook("loader-savetasknotes", _on_save_task_notes)
    lib.hook("loader-loadtasknotes", _on_load_task_notes)


func _save_path(loader: Node) -> String:
    return loader.get_meta(&"savePath", "user://")


func _player_save_path(loader: Node) -> String:
    return loader.get_meta(&"playerSavePath", "user://")


func _ensure_save_dir(loader: Node) -> void:
    var sp: String = _save_path(loader)
    var pp: String = _player_save_path(loader)
    if sp != "user://" && !DirAccess.dir_exists_absolute(sp):
        DirAccess.make_dir_recursive_absolute(sp)
    if pp != "user://" && !DirAccess.dir_exists_absolute(pp):
        DirAccess.make_dir_recursive_absolute(pp)


func _on_reset_character() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    var character: CharacterSave = CharacterSave.new()
    character.cat = loader.gameData.cat
    character.catFound = loader.gameData.catFound
    character.catDead = loader.gameData.catDead
    var pp: String = _player_save_path(loader)
    ResourceSaver.save(character, pp + "Character.tres")
    CoopManager._log("[loader] ResetCharacter path=%s" % pp)


func _on_save_character() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    var character: CharacterSave = CharacterSave.new()
    character.initialSpawn = false
    character.startingKit = null

    var iface: Node = loader.get_tree().current_scene.get_node(PATH_INTERFACE)

    _save_vitals(loader, character)
    _save_cat(loader, character)
    _save_loadout(loader, character)
    _save_inventory_grids(character, iface)

    var pp: String = _player_save_path(loader)
    ResourceSaver.save(character, pp + "Character.tres")
    CoopManager._log("[loader] SaveCharacter path=%s session=%s host=%s" % [pp, str(CoopManager.is_session_active()), str(CoopManager.isHost)])
    if CoopManager.is_session_active():
        CoopManager._log("[loader] SaveCharacter → send_character_to_host")
        CoopManager.send_character_to_host()


func _save_vitals(loader: Node, character: CharacterSave) -> void:
    var gd: GameData = loader.gameData
    character.health = gd.health
    character.energy = gd.energy
    character.hydration = gd.hydration
    character.mental = gd.mental
    character.temperature = gd.temperature
    character.bodyStamina = gd.bodyStamina
    character.armStamina = gd.armStamina
    character.overweight = gd.overweight
    character.starvation = gd.starvation
    character.dehydration = gd.dehydration
    character.bleeding = gd.bleeding
    character.fracture = gd.fracture
    character.burn = gd.burn
    character.frostbite = gd.frostbite
    character.insanity = gd.insanity
    character.rupture = gd.rupture
    character.headshot = gd.headshot


func _save_cat(loader: Node, character: CharacterSave) -> void:
    character.cat = loader.gameData.cat
    character.catFound = loader.gameData.catFound
    character.catDead = loader.gameData.catDead


func _save_loadout(loader: Node, character: CharacterSave) -> void:
    var gd: GameData = loader.gameData
    character.primary = gd.primary
    character.secondary = gd.secondary
    character.knife = gd.knife
    character.grenade1 = gd.grenade1
    character.grenade2 = gd.grenade2
    character.flashlight = gd.flashlight
    character.NVG = gd.NVG


func _save_inventory_grids(character: CharacterSave, iface: Node) -> void:
    character.inventory.clear()
    character.equipment.clear()
    character.catalog.clear()

    for item: Node in iface.inventoryGrid.get_children():
        var newSlotData: SlotData = SlotData.new()
        newSlotData.Update(item.slotData)
        newSlotData.GridSave(item.position, item.rotated)
        character.inventory.append(newSlotData)

    for equipmentSlot: Node in iface.equipment.get_children():
        if equipmentSlot.get_child_count() != 0 && equipmentSlot.get_child(0).get(&"slotData") != null:
            var slotItem: Node = equipmentSlot.get_child(0)
            var newSlotData: SlotData = SlotData.new()
            newSlotData.Update(slotItem.slotData)
            newSlotData.SlotSave(equipmentSlot.name)
            character.equipment.append(newSlotData)

    for item: Node in iface.catalogGrid.get_children():
        var newSlotData: SlotData = SlotData.new()
        newSlotData.Update(item.slotData)
        newSlotData.GridSave(item.position, item.rotated)
        if item.slotData.storage.size() != 0:
            newSlotData.storage = item.slotData.storage
        character.catalog.append(newSlotData)


func _on_load_character() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var pp: String = _player_save_path(loader)
    if _loadCharacterInProgress:
        CoopManager._log("[loader] LoadCharacter SKIP reentry path=%s" % pp)
        return
    _loadCharacterInProgress = true
    
    var tree: SceneTree = loader.get_tree()
    await tree.create_timer(0.1).timeout

    if !FileAccess.file_exists(pp + "Character.tres"):
        CoopManager._log("[loader] LoadCharacter NO_FILE path=%s" % pp)
        _loadCharacterInProgress = false
        return

    CoopManager._log("[loader] LoadCharacter BEGIN path=%s host=%s" % [pp, str(CoopManager.isHost)])
    var character: CharacterSave = load(pp + "Character.tres") as CharacterSave

    var rigManager: Node = tree.current_scene.get_node(PATH_RIG_MANAGER)
    var iface: Node = tree.current_scene.get_node(PATH_INTERFACE)
    var flashlight: Node = tree.current_scene.get_node(PATH_FLASHLIGHT)
    var NVG: Node = tree.current_scene.get_node(PATH_NVG)

    # Coop reloads (sleep/Killbox/handoff) re-enter LoadCharacter on the same
    # Interface instance. Vanilla skips clear because scene transitions destroy
    # + recreate Interface. Item-only filter preserves Slot.hint Labels.
    _clear_grid_children(iface.inventoryGrid)
    _clear_equipment_slots(iface.equipment)
    _clear_grid_children(iface.catalogGrid)
    await tree.process_frame

    _load_initial_kit(character, iface)
    _load_inventory_grids(character, iface)
    iface.UpdateStats(false)

    _load_vitals(loader, character)
    _load_cat(loader, character)
    _load_loadout(loader, character)
    _equip_active_rig(loader, character, rigManager, flashlight, NVG)

    loader.UpdateProgression()
    CoopManager._log("[loader] LoadCharacter END path=%s inv=%d eq=%d cat=%d" % [pp, character.inventory.size(), character.equipment.size(), character.catalog.size()])
    _loadCharacterInProgress = false


func _load_initial_kit(character: CharacterSave, iface: Node) -> void:
    if !(character.initialSpawn && character.startingKit):
        return
    for item: Resource in character.startingKit.items:
        var newSlotData: SlotData = SlotData.new()
        newSlotData.itemData = item
        if newSlotData.itemData.stackable:
            newSlotData.amount = newSlotData.itemData.defaultAmount
        iface.Create(newSlotData, iface.inventoryGrid, false)


func _load_inventory_grids(character: CharacterSave, iface: Node) -> void:
    for slotData: SlotData in character.inventory:
        iface.LoadGridItem(slotData, iface.inventoryGrid, slotData.gridPosition)
    for slotData: SlotData in character.equipment:
        iface.LoadSlotItem(slotData, slotData.slot)
    for slotData: SlotData in character.catalog:
        iface.LoadGridItem(slotData, iface.catalogGrid, slotData.gridPosition)


func _clear_grid_children(grid: Node) -> void:
    if grid == null:
        return
    for item: Node in grid.get_children():
        grid.remove_child(item)
        item.queue_free()


## Equipment slot panels embed a hint Label child set up via @export at scene
## load (Slot.gd: @export var hint: Label). Removing all children would null
## that ref and crash any subsequent slot.hint.show()/hide() in vanilla code
## (Equip/Unequip/Map/CasettePlayer). Filter to Item children only.
func _clear_equipment_slots(equipment: Node) -> void:
    if equipment == null:
        return
    for slot: Node in equipment.get_children():
        for child: Node in slot.get_children():
            if child is Item:
                slot.remove_child(child)
                child.queue_free()


func _load_vitals(loader: Node, character: CharacterSave) -> void:
    var gd: GameData = loader.gameData
    gd.health = character.health
    gd.energy = character.energy
    gd.hydration = character.hydration
    gd.mental = character.mental
    gd.temperature = character.temperature
    gd.bodyStamina = character.bodyStamina
    gd.armStamina = character.armStamina
    gd.overweight = character.overweight
    gd.starvation = character.starvation
    gd.dehydration = character.dehydration
    gd.bleeding = character.bleeding
    gd.fracture = character.fracture
    gd.burn = character.burn
    gd.frostbite = character.frostbite
    gd.insanity = character.insanity
    gd.rupture = character.rupture
    gd.headshot = character.headshot


func _load_cat(loader: Node, character: CharacterSave) -> void:
    loader.gameData.cat = character.cat
    loader.gameData.catFound = character.catFound
    loader.gameData.catDead = character.catDead


func _load_loadout(loader: Node, character: CharacterSave) -> void:
    var gd: GameData = loader.gameData
    gd.primary = character.primary
    gd.secondary = character.secondary
    gd.knife = character.knife
    gd.grenade1 = character.grenade1
    gd.grenade2 = character.grenade2
    gd.flashlight = character.flashlight
    gd.NVG = character.NVG


func _equip_active_rig(loader: Node, character: CharacterSave, rigManager: Node, flashlight: Node, NVG: Node) -> void:
    var gd: GameData = loader.gameData
    if gd.primary:
        rigManager.LoadPrimary()
        gd.weaponPosition = character.weaponPosition
    elif gd.secondary:
        rigManager.LoadSecondary()
        gd.weaponPosition = character.weaponPosition
    elif gd.knife:
        rigManager.LoadKnife()
    elif gd.grenade1:
        rigManager.LoadGrenade1()
    elif gd.grenade2:
        rigManager.LoadGrenade2()

    if gd.flashlight:
        flashlight.Load()
    if gd.NVG:
        NVG.Load()


func _on_new_game(difficulty: int, season: int) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    loader.FormatSave()

    var sp: String = _save_path(loader)
    var pp: String = _player_save_path(loader)

    var world: WorldSave = WorldSave.new()
    world.difficulty = difficulty
    world.season = season
    world.day = 1
    if difficulty == 1:
        world.time = 800
        world.weather = "Neutral"
    if difficulty != 1:
        world.time = randi_range(0, 2400)
        world.weather = loader.randomWeathers.pick_random()
    ResourceSaver.save(world, sp + "World.tres")

    var character: CharacterSave = CharacterSave.new()
    if difficulty == 1:
        character.initialSpawn = true
        if loader.startingKits.size() != 0:
            var randomKit: Resource = loader.startingKits.pick_random()
            if randomKit.items.size() != 0:
                character.startingKit = randomKit
    if difficulty != 1:
        character.health = randi_range(25, 100)
        character.hydration = randi_range(25, 100)
        character.energy = randi_range(25, 100)
        character.mental = randi_range(25, 100)
        character.temperature = randi_range(25, 100)
    ResourceSaver.save(character, pp + "Character.tres")

    var traders: TraderSave = TraderSave.new()
    ResourceSaver.save(traders, sp + "Traders.tres")

    var cabin: ShelterSave = ShelterSave.new()
    cabin.initialVisit = true
    ResourceSaver.save(cabin, sp + "Cabin.tres")

    var tent: ShelterSave = ShelterSave.new()
    tent.initialVisit = true
    ResourceSaver.save(tent, sp + "Tent.tres")

    CoopManager._log("[loader] NewGame difficulty=%d season=%d path=%s playerPath=%s" % [difficulty, season, sp, pp])


func _on_save_world() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    var sp: String = _save_path(loader)
    var world: WorldSave = WorldSave.new()
    world.season = Simulation.season
    world.time = Simulation.time
    world.day = Simulation.day
    world.weather = Simulation.weather
    world.weatherTime = Simulation.weatherTime
    world.difficulty = loader.gameData.difficulty
    ResourceSaver.save(world, sp + "World.tres")
    print("SAVE: World (%s)" % sp)


func _on_load_world() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    if !FileAccess.file_exists(sp + "World.tres"):
        return
    var world: WorldSave = load(sp + "World.tres") as WorldSave
    Simulation.season = world.season
    Simulation.time = world.time
    Simulation.day = world.day
    Simulation.weather = world.weather
    Simulation.weatherTime = world.weatherTime
    if world.difficulty == 3 && !loader.gameData.tutorial:
        loader.gameData.difficulty = 3
        loader.gameData.permadeath = true
    print("LOAD: World (%s)" % sp)


func _on_format_save() -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    var directory: DirAccess = DirAccess.open(sp)
    if !directory:
        return
    directory.list_dir_begin()
    var file: String = directory.get_next()
    while file != "":
        if file.ends_with(".tres") && file != "Validator.tres" && file != "Preferences.tres":
            var removal: int = directory.remove(sp + file)
            if removal == OK:
                print("File removed: " + file)
            else:
                push_warning("FormatSave: failed to remove %s (error %d)" % [file, removal])
        file = directory.get_next()
    directory.list_dir_end()


func _on_validate_shelter() -> String:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return ""
    _lib.skip_super()
    var sp: String = _save_path(loader)
    var directory: DirAccess = DirAccess.open(sp)
    if !directory:
        return ""
    directory.list_dir_begin()
    var lastVisit: int = 0
    var lastShelter: String = ""
    var file: String = directory.get_next()
    while file != "":
        if file.ends_with(".tres"):
            var filePath: String = sp + file
            var resource: Resource = load(filePath)
            if resource is ShelterSave:
                if resource.lastVisit > lastVisit:
                    lastShelter = file.replace(".tres", "")
                    lastVisit = resource.lastVisit
        file = directory.get_next()
    directory.list_dir_end()
    return lastShelter


func _on_save_shelter(targetShelter: String) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    var sp: String = _save_path(loader)
    var shelter: ShelterSave = ShelterSave.new()
    shelter.initialVisit = false
    shelter.lastVisit = (Simulation.day * 10000) + Simulation.time

    for furniture: Node in loader.get_tree().get_nodes_in_group(&"Furniture"):
        var furnitureComponent: Node = null
        for child: Node in furniture.owner.get_children():
            if child.get(&"itemData") != null:
                furnitureComponent = child
        if furnitureComponent != null:
            var furnitureSave: FurnitureSave = FurnitureSave.new()
            furnitureSave.name = furnitureComponent.itemData.name
            furnitureSave.itemData = furnitureComponent.itemData
            furnitureSave.position = furniture.owner.global_position
            furnitureSave.rotation = furniture.owner.global_rotation
            furnitureSave.scale = furniture.owner.scale
            var storageVal: Variant = furniture.owner.get(&"storage")
            if storageVal != null && storageVal is Array && storageVal.size() != 0:
                furnitureSave.storage = storageVal
            shelter.furnitures.append(furnitureSave)

    for item: Node in loader.get_tree().get_nodes_in_group(&"Item"):
        if !item.global_position.is_finite() || !item.global_rotation.is_finite():
            continue
        if item.global_position.y < -10.0:
            continue
        var itemSave: ItemSave = ItemSave.new()
        itemSave.name = item.slotData.itemData.name
        itemSave.slotData = item.slotData
        itemSave.position = item.global_position
        itemSave.rotation = item.global_rotation
        shelter.items.append(itemSave)

    for switchNode: Node in loader.get_tree().get_nodes_in_group(&"Switch"):
        var switchSave: SwitchSave = SwitchSave.new()
        switchSave.name = switchNode.name
        switchSave.active = switchNode.active
        shelter.switches.append(switchSave)

    ResourceSaver.save(shelter, sp + targetShelter + ".tres")
    print("SAVE: %s (%s)" % [targetShelter, sp])


func _on_load_shelter(targetShelter: String) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    await loader.get_tree().create_timer(0.1).timeout
    if !FileAccess.file_exists(sp + targetShelter + ".tres"):
        return

    var shelter: ShelterSave = load(sp + targetShelter + ".tres") as ShelterSave

    if shelter.initialVisit:
        loader.UpdateProgression()

    if !shelter.initialVisit:
        for furniture: Node in loader.get_tree().get_nodes_in_group(&"Furniture"):
            furniture.owner.global_position.y = -100.0
            furniture.queue_free()

    for furnitureSave: FurnitureSave in shelter.furnitures:
        var file: PackedScene = Database.get(furnitureSave.itemData.file)
        if !file:
            continue
        var furniture: Node3D = Database.get(furnitureSave.itemData.file).instantiate()
        var map: Node = loader.get_tree().current_scene.get_node(PATH_MAP)
        map.add_child(furniture)
        furniture.name = furnitureSave.name
        furniture.global_position = furnitureSave.position
        furniture.global_rotation = furnitureSave.rotation
        furniture.scale = furnitureSave.scale
        if furniture is LootContainer:
            if furnitureSave.storage.size() != 0:
                furniture.storage = furnitureSave.storage
                furniture.storaged = true

    for item: ItemSave in shelter.items:
        var file: PackedScene = Database.get(item.slotData.itemData.file)
        if !file:
            continue
        if !item.position.is_finite() || !item.rotation.is_finite():
            continue
        if item.position.y < -10.0:
            continue
        var pickup: Node3D = Database.get(item.slotData.itemData.file).instantiate()
        var map: Node = loader.get_tree().current_scene.get_node(PATH_MAP)
        map.add_child(pickup)
        pickup.slotData.Update(item.slotData)
        pickup.name = item.name
        pickup.global_position = item.position
        pickup.global_rotation = item.rotation
        pickup.Freeze()
        pickup.UpdateAttachments()

    for switchNode: Node in loader.get_tree().get_nodes_in_group(&"Switch"):
        for switchSave: SwitchSave in shelter.switches:
            if switchSave.name == switchNode.name:
                if switchSave.active:
                    switchNode.Activate()
                else:
                    switchNode.Deactivate()


func _on_check_shelter_state(targetShelter: String) -> bool:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return false
    _lib.skip_super()
    var sp: String = _save_path(loader)
    return FileAccess.file_exists(sp + targetShelter + ".tres")


func _on_unlock_shelter(targetShelter: String) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    _ensure_save_dir(loader)
    var sp: String = _save_path(loader)
    var shelter: ShelterSave = ShelterSave.new()
    shelter.initialVisit = true
    ResourceSaver.save(shelter, sp + targetShelter + ".tres")
    print("Shelter Unlocked: %s (%s)" % [targetShelter, sp])
    loader.UpdateProgression()


func _on_save_trader(trader: String) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    if !FileAccess.file_exists(sp + "Traders.tres"):
        return
    var traders: TraderSave = load(sp + "Traders.tres") as TraderSave
    var iface: Node = loader.get_tree().current_scene.get_node(PATH_INTERFACE)

    if trader == "Generalist": traders.generalist.clear()
    elif trader == "Doctor": traders.doctor.clear()
    elif trader == "Gunsmith": traders.gunsmith.clear()
    elif trader == "Grandma": traders.grandma.clear()

    for taskString: String in iface.trader.tasksCompleted:
        if trader == "Generalist": traders.generalist.append(taskString)
        elif trader == "Doctor": traders.doctor.append(taskString)
        elif trader == "Gunsmith": traders.gunsmith.append(taskString)
        elif trader == "Grandma": traders.grandma.append(taskString)

    ResourceSaver.save(traders, sp + "Traders.tres")
    print("SAVE: Traders (%s) at %s" % [trader, sp])


func _on_load_trader(trader: String) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    await loader.get_tree().create_timer(0.1).timeout
    if !FileAccess.file_exists(sp + "Traders.tres"):
        return

    var traders: TraderSave = load(sp + "Traders.tres") as TraderSave
    var iface: Node = loader.get_tree().current_scene.get_node(PATH_INTERFACE)
    iface.trader.tasksCompleted.clear()

    if trader == "Generalist":
        for taskString: String in traders.generalist:
            iface.trader.tasksCompleted.append(taskString)
    elif trader == "Doctor":
        for taskString: String in traders.doctor:
            iface.trader.tasksCompleted.append(taskString)
    elif trader == "Gunsmith":
        for taskString: String in traders.gunsmith:
            iface.trader.tasksCompleted.append(taskString)
    elif trader == "Grandma":
        for taskString: String in traders.grandma:
            iface.trader.tasksCompleted.append(taskString)

    iface.UpdateTraderInfo()
    print("LOAD: Traders (%s) at %s" % [trader, sp])


func _on_save_task_notes(task: TaskData, add: bool) -> void:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return
    _lib.skip_super()
    var sp: String = _save_path(loader)
    if !FileAccess.file_exists(sp + "Traders.tres"):
        return
    var traders: TraderSave = load(sp + "Traders.tres") as TraderSave
    if add:
        if traders.taskNotes.size() == 0 || !traders.taskNotes.has(task):
            traders.taskNotes.append(task)
    if !add:
        if traders.taskNotes.has(task):
            traders.taskNotes.erase(task)
    ResourceSaver.save(traders, sp + "Traders.tres")


func _on_load_task_notes() -> Array[TaskData]:
    var loader: CanvasLayer = _lib._caller as CanvasLayer
    if loader == null:
        return []
    _lib.skip_super()
    var sp: String = _save_path(loader)
    if !FileAccess.file_exists(sp + "Traders.tres"):
        return []
    var traders: TraderSave = load(sp + "Traders.tres") as TraderSave
    return traders.taskNotes
