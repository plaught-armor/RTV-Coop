## Patch for Loader.gd — per-world savePath (world data) + playerSavePath (character).
extends "res://Scripts/Loader.gd"

var savePath: String = "user://"
var playerSavePath: String = "user://"

const PATH_INTERFACE: NodePath = ^"/root/Map/Core/UI/Interface"
const PATH_RIG_MANAGER: NodePath = ^"/root/Map/Core/Camera/Manager"
const PATH_FLASHLIGHT: NodePath = ^"/root/Map/Core/Camera/Flashlight"
const PATH_NVG: NodePath = ^"/root/Map/Core/UI/NVG"
const PATH_MAP: NodePath = ^"/root/Map"


func _ensure_save_dir() -> void:
    if savePath != "user://" && !DirAccess.dir_exists_absolute(savePath):
        DirAccess.make_dir_recursive_absolute(savePath)
    if playerSavePath != "user://" && !DirAccess.dir_exists_absolute(playerSavePath):
        DirAccess.make_dir_recursive_absolute(playerSavePath)


func ResetCharacter():
    _ensure_save_dir()
    var character: CharacterSave = CharacterSave.new()
    character.cat = gameData.cat
    character.catFound = gameData.catFound
    character.catDead = gameData.catDead
    ResourceSaver.save(character, playerSavePath + "Character.tres")
    _dbg_print("Loader: Reset Character (%s)" % playerSavePath)


func SaveCharacter():
    _ensure_save_dir()
    var character: CharacterSave = CharacterSave.new()
    character.initialSpawn = false
    character.startingKit = null

    var interface = get_tree().current_scene.get_node(PATH_INTERFACE)

    _save_vitals(character)
    _save_cat(character)
    _save_loadout(character)
    _save_inventory_grids(character, interface)

    ResourceSaver.save(character, playerSavePath + "Character.tres")
    _dbg_print("SAVE: Character (%s)" % playerSavePath)
    var root: Node = get_tree().root if get_tree() != null else null
    if root != null:
        for child: Node in root.get_children():
            if child.has_meta(&"is_coop_manager") && child.is_session_active():
                child.send_character_to_host()
                break


func _dbg_print(msg: String) -> void:
    var root: Node = get_tree().root if get_tree() != null else null
    if root == null:
        return
    for child: Node in root.get_children():
        if child.has_meta(&"is_coop_manager") && child.DEBUG:
            print(msg)
            return


func _save_vitals(character: CharacterSave) -> void:
    character.health = gameData.health
    character.energy = gameData.energy
    character.hydration = gameData.hydration
    character.mental = gameData.mental
    character.temperature = gameData.temperature
    character.bodyStamina = gameData.bodyStamina
    character.armStamina = gameData.armStamina
    character.overweight = gameData.overweight
    character.starvation = gameData.starvation
    character.dehydration = gameData.dehydration
    character.bleeding = gameData.bleeding
    character.fracture = gameData.fracture
    character.burn = gameData.burn
    character.frostbite = gameData.frostbite
    character.insanity = gameData.insanity
    character.rupture = gameData.rupture
    character.headshot = gameData.headshot


func _save_cat(character: CharacterSave) -> void:
    character.cat = gameData.cat
    character.catFound = gameData.catFound
    character.catDead = gameData.catDead


func _save_loadout(character: CharacterSave) -> void:
    character.primary = gameData.primary
    character.secondary = gameData.secondary
    character.knife = gameData.knife
    character.grenade1 = gameData.grenade1
    character.grenade2 = gameData.grenade2
    character.flashlight = gameData.flashlight
    character.NVG = gameData.NVG


func _save_inventory_grids(character: CharacterSave, interface) -> void:
    character.inventory.clear()
    character.equipment.clear()
    character.catalog.clear()

    for item in interface.inventoryGrid.get_children():
        var newSlotData = SlotData.new()
        newSlotData.Update(item.slotData)
        newSlotData.GridSave(item.position, item.rotated)
        character.inventory.append(newSlotData)

    for equipmentSlot in interface.equipment.get_children():
        # Duck-typed: Slot class_name unreliable after take_over_path; treat any child holding a slotItem as an equip slot.
        if equipmentSlot.get_child_count() != 0 && equipmentSlot.get_child(0).get(&"slotData") != null:
            var slotItem = equipmentSlot.get_child(0)
            var newSlotData = SlotData.new()
            newSlotData.Update(slotItem.slotData)
            newSlotData.SlotSave(equipmentSlot.name)
            character.equipment.append(newSlotData)

    for item in interface.catalogGrid.get_children():
        var newSlotData = SlotData.new()
        newSlotData.Update(item.slotData)
        newSlotData.GridSave(item.position, item.rotated)
        if item.slotData.storage.size() != 0:
            newSlotData.storage = item.slotData.storage
        character.catalog.append(newSlotData)


func LoadCharacter():
    await get_tree().create_timer(0.1).timeout;

    if !FileAccess.file_exists(playerSavePath + "Character.tres"):
        return

    var character: CharacterSave = load(playerSavePath + "Character.tres") as CharacterSave

    var rigManager = get_tree().current_scene.get_node(PATH_RIG_MANAGER)
    var interface = get_tree().current_scene.get_node(PATH_INTERFACE)
    var flashlight = get_tree().current_scene.get_node(PATH_FLASHLIGHT)
    var NVG = get_tree().current_scene.get_node(PATH_NVG)

    # Coop reloads (sleep/Killbox/handoff) can re-enter with stale grids — clear before load.
    _clear_grid_children(interface.inventoryGrid)
    _clear_equipment_slots(interface.equipment)
    _clear_grid_children(interface.catalogGrid)
    # Wait a frame so queue_free'd children don't collide with LoadGridItem layout.
    await get_tree().process_frame

    _load_initial_kit(character, interface)
    _load_inventory_grids(character, interface)
    interface.UpdateStats(false)

    _load_vitals(character)
    _load_cat(character)
    _load_loadout(character)
    _equip_active_rig(character, rigManager, flashlight, NVG)

    UpdateProgression()
    print("LOAD: Character (%s)" % playerSavePath)


func _load_initial_kit(character: CharacterSave, interface) -> void:
    if !(character.initialSpawn && character.startingKit):
        return
    for item in character.startingKit.items:
        var newSlotData = SlotData.new()
        newSlotData.itemData = item
        if newSlotData.itemData.stackable:
            newSlotData.amount = newSlotData.itemData.defaultAmount
        interface.Create(newSlotData, interface.inventoryGrid, false)


func _load_inventory_grids(character: CharacterSave, interface) -> void:
    for slotData in character.inventory:
        interface.LoadGridItem(slotData, interface.inventoryGrid, slotData.gridPosition)
    for slotData in character.equipment:
        interface.LoadSlotItem(slotData, slotData.slot)
    for slotData in character.catalog:
        interface.LoadGridItem(slotData, interface.catalogGrid, slotData.gridPosition)


# remove_child is synchronous so the grid is empty before LoadGridItem layout runs.
func _clear_grid_children(grid: Node) -> void:
    if grid == null:
        return
    for item: Node in grid.get_children():
        grid.remove_child(item)
        item.queue_free()


func _clear_equipment_slots(equipment: Node) -> void:
    if equipment == null:
        return
    for slot: Node in equipment.get_children():
        for child: Node in slot.get_children():
            slot.remove_child(child)
            child.queue_free()


func _load_vitals(character: CharacterSave) -> void:
    gameData.health = character.health
    gameData.energy = character.energy
    gameData.hydration = character.hydration
    gameData.mental = character.mental
    gameData.temperature = character.temperature
    gameData.bodyStamina = character.bodyStamina
    gameData.armStamina = character.armStamina
    gameData.overweight = character.overweight
    gameData.starvation = character.starvation
    gameData.dehydration = character.dehydration
    gameData.bleeding = character.bleeding
    gameData.fracture = character.fracture
    gameData.burn = character.burn
    gameData.frostbite = character.frostbite
    gameData.insanity = character.insanity
    gameData.rupture = character.rupture
    gameData.headshot = character.headshot


func _load_cat(character: CharacterSave) -> void:
    gameData.cat = character.cat
    gameData.catFound = character.catFound
    gameData.catDead = character.catDead


func _load_loadout(character: CharacterSave) -> void:
    gameData.primary = character.primary
    gameData.secondary = character.secondary
    gameData.knife = character.knife
    gameData.grenade1 = character.grenade1
    gameData.grenade2 = character.grenade2
    gameData.flashlight = character.flashlight
    gameData.NVG = character.NVG


func _equip_active_rig(character: CharacterSave, rigManager, flashlight, NVG) -> void:
    if gameData.primary:
        rigManager.LoadPrimary()
        gameData.weaponPosition = character.weaponPosition
    elif gameData.secondary:
        rigManager.LoadSecondary()
        gameData.weaponPosition = character.weaponPosition
    elif gameData.knife:
        rigManager.LoadKnife()
    elif gameData.grenade1:
        rigManager.LoadGrenade1()
    elif gameData.grenade2:
        rigManager.LoadGrenade2()

    if gameData.flashlight:
        flashlight.Load()
    if gameData.NVG:
        NVG.Load()


func NewGame(difficulty, season):
    _ensure_save_dir()
    FormatSave()

    var world: WorldSave = WorldSave.new()
    world.difficulty = difficulty
    world.season = season
    world.day = 1
    if difficulty == 1:
        world.time = 800
        world.weather = "Neutral"
    if difficulty != 1:
        world.time = randi_range(0, 2400)
        world.weather = randomWeathers.pick_random()
    ResourceSaver.save(world, savePath + "World.tres")

    var character: CharacterSave = CharacterSave.new()
    if difficulty == 1:
        character.initialSpawn = true
        if startingKits.size() != 0:
            var randomKit = startingKits.pick_random()
            if randomKit.items.size() != 0:
                character.startingKit = randomKit
    if difficulty != 1:
        character.health = randi_range(25, 100)
        character.hydration = randi_range(25, 100)
        character.energy = randi_range(25, 100)
        character.mental = randi_range(25, 100)
        character.temperature = randi_range(25, 100)
    ResourceSaver.save(character, playerSavePath + "Character.tres")

    var traders: TraderSave = TraderSave.new()
    ResourceSaver.save(traders, savePath + "Traders.tres")

    var cabin: ShelterSave = ShelterSave.new()
    cabin.initialVisit = true
    ResourceSaver.save(cabin, savePath + "Cabin.tres")

    var tent: ShelterSave = ShelterSave.new()
    tent.initialVisit = true
    ResourceSaver.save(tent, savePath + "Tent.tres")

    print("Loader: New Game (%d / %d) at %s" % [difficulty, season, savePath])


func SaveWorld():
    _ensure_save_dir()
    var world: WorldSave = WorldSave.new()
    world.season = Simulation.season
    world.time = Simulation.time
    world.day = Simulation.day
    world.weather = Simulation.weather
    world.weatherTime = Simulation.weatherTime
    world.difficulty = gameData.difficulty
    ResourceSaver.save(world, savePath + "World.tres")
    print("SAVE: World (%s)" % savePath)


func LoadWorld():
    if !FileAccess.file_exists(savePath + "World.tres"):
        return
    var world: WorldSave = load(savePath + "World.tres") as WorldSave
    Simulation.season = world.season
    Simulation.time = world.time
    Simulation.day = world.day
    Simulation.weather = world.weather
    Simulation.weatherTime = world.weatherTime
    if world.difficulty == 3 && !gameData.tutorial:
        gameData.difficulty = 3
        gameData.permadeath = true
    print("LOAD: World (%s)" % savePath)


func FormatSave():
    var directory = DirAccess.open(savePath)
    if !directory:
        return
    directory.list_dir_begin()
    var file = directory.get_next()
    while file != "":
        if file.ends_with(".tres") && file != "Validator.tres" && file != "Preferences.tres":
            var removal = directory.remove(savePath + file)
            if removal == OK:
                print("File removed: " + file)
            else:
                push_warning("FormatSave: failed to remove %s (error %d)" % [file, removal])
        file = directory.get_next()
    directory.list_dir_end()


func ValidateShelter() -> String:
    var directory = DirAccess.open(savePath)
    if !directory:
        return ""
    directory.list_dir_begin()
    var lastVisit = 0
    var lastShelter = ""
    var file = directory.get_next()
    while file != "":
        if file.ends_with(".tres"):
            var filePath = savePath + file
            var resource = load(filePath)
            if resource is ShelterSave:
                if resource.lastVisit > lastVisit:
                    lastShelter = file.replace(".tres", "")
                    lastVisit = resource.lastVisit
        file = directory.get_next()
    directory.list_dir_end()
    return lastShelter


func SaveShelter(targetShelter):
    _ensure_save_dir()
    var shelter: ShelterSave = ShelterSave.new()
    shelter.initialVisit = false
    shelter.lastVisit = (Simulation.day * 10000) + Simulation.time

    for furniture in get_tree().get_nodes_in_group(&"Furniture"):
        # Duck-typed: Furniture class_name false-positives on siblings after take_over_path patches it.
        # `itemData` is Furniture's distinguishing prop; .get(&"itemData") returns null on other node types.
        var furnitureComponent: Node = null
        for child in furniture.owner.get_children():
            if child.get(&"itemData") != null:
                furnitureComponent = child
        if furnitureComponent != null:
            var furnitureSave = FurnitureSave.new()
            furnitureSave.name = furnitureComponent.itemData.name
            furnitureSave.itemData = furnitureComponent.itemData
            furnitureSave.position = furniture.owner.global_position
            furnitureSave.rotation = furniture.owner.global_rotation
            furnitureSave.scale = furniture.owner.scale
            # LootContainer detection via duck-typing (`storage` prop) — safe if LootContainer.gd ever gets patched.
            var storageVal: Variant = furniture.owner.get(&"storage")
            if storageVal != null && storageVal is Array && storageVal.size() != 0:
                furnitureSave.storage = storageVal
            shelter.furnitures.append(furnitureSave)

    for item in get_tree().get_nodes_in_group(&"Item"):
        if !item.global_position.is_finite() || !item.global_rotation.is_finite():
            continue
        if item.global_position.y < -10.0:
            continue
        var itemSave = ItemSave.new()
        itemSave.name = item.slotData.itemData.name
        itemSave.slotData = item.slotData
        itemSave.position = item.global_position
        itemSave.rotation = item.global_rotation
        shelter.items.append(itemSave)

    for switch in get_tree().get_nodes_in_group(&"Switch"):
        var switchSave = SwitchSave.new()
        switchSave.name = switch.name
        switchSave.active = switch.active
        shelter.switches.append(switchSave)

    ResourceSaver.save(shelter, savePath + targetShelter + ".tres")
    print("SAVE: %s (%s)" % [targetShelter, savePath])


func LoadShelter(targetShelter):
    await get_tree().create_timer(0.1).timeout;
    if !FileAccess.file_exists(savePath + targetShelter + ".tres"):
        return

    var shelter: ShelterSave = load(savePath + targetShelter + ".tres") as ShelterSave
    print("LOAD: %s (%s)" % [targetShelter, savePath])

    if shelter.initialVisit:
        UpdateProgression()

    if !shelter.initialVisit:
        for furniture in get_tree().get_nodes_in_group(&"Furniture"):
            furniture.owner.global_position.y = -100.0
            furniture.queue_free()

    for furnitureSave in shelter.furnitures:
        var file = Database.get(furnitureSave.itemData.file)
        if !file:
            continue
        var furniture = Database.get(furnitureSave.itemData.file).instantiate()
        var map = get_tree().current_scene.get_node(PATH_MAP)
        map.add_child(furniture)
        furniture.name = furnitureSave.name
        furniture.global_position = furnitureSave.position
        furniture.global_rotation = furnitureSave.rotation
        furniture.scale = furnitureSave.scale
        if furniture is LootContainer:
            if furnitureSave.storage.size() != 0:
                furniture.storage = furnitureSave.storage
                furniture.storaged = true

    for item in shelter.items:
        var file = Database.get(item.slotData.itemData.file)
        if !file:
            continue
        if !item.position.is_finite() || !item.rotation.is_finite():
            continue
        if item.position.y < -10.0:
            continue
        var pickup = Database.get(item.slotData.itemData.file).instantiate()
        var map = get_tree().current_scene.get_node(PATH_MAP)
        map.add_child(pickup)
        pickup.slotData.Update(item.slotData)
        pickup.name = item.name
        pickup.global_position = item.position
        pickup.global_rotation = item.rotation
        pickup.Freeze()
        pickup.UpdateAttachments()

    for switch in get_tree().get_nodes_in_group(&"Switch"):
        for switchSave in shelter.switches:
            if switchSave.name == switch.name:
                if switchSave.active:
                    switch.Activate()
                else:
                    switch.Deactivate()


func CheckShelterState(targetShelter) -> bool:
    return FileAccess.file_exists(savePath + targetShelter + ".tres")


func UnlockShelter(targetShelter):
    _ensure_save_dir()
    var shelter: ShelterSave = ShelterSave.new()
    shelter.initialVisit = true
    ResourceSaver.save(shelter, savePath + targetShelter + ".tres")
    print("Shelter Unlocked: %s (%s)" % [targetShelter, savePath])
    UpdateProgression()


func SaveTrader(trader: String):
    if !FileAccess.file_exists(savePath + "Traders.tres"):
        return
    var traders = load(savePath + "Traders.tres") as TraderSave
    var interface = get_tree().current_scene.get_node(PATH_INTERFACE)

    if trader == "Generalist": traders.generalist.clear()
    elif trader == "Doctor": traders.doctor.clear()
    elif trader == "Gunsmith": traders.gunsmith.clear()
    elif trader == "Grandma": traders.grandma.clear()

    for taskString in interface.trader.tasksCompleted:
        if trader == "Generalist": traders.generalist.append(taskString)
        elif trader == "Doctor": traders.doctor.append(taskString)
        elif trader == "Gunsmith": traders.gunsmith.append(taskString)
        elif trader == "Grandma": traders.grandma.append(taskString)

    ResourceSaver.save(traders, savePath + "Traders.tres")
    print("SAVE: Traders (%s) at %s" % [trader, savePath])


func LoadTrader(trader: String):
    await get_tree().create_timer(0.1).timeout;
    if !FileAccess.file_exists(savePath + "Traders.tres"):
        return

    var traders = load(savePath + "Traders.tres") as TraderSave
    var interface = get_tree().current_scene.get_node(PATH_INTERFACE)
    interface.trader.tasksCompleted.clear()

    if trader == "Generalist":
        for taskString in traders.generalist:
            interface.trader.tasksCompleted.append(taskString)
    elif trader == "Doctor":
        for taskString in traders.doctor:
            interface.trader.tasksCompleted.append(taskString)
    elif trader == "Gunsmith":
        for taskString in traders.gunsmith:
            interface.trader.tasksCompleted.append(taskString)
    elif trader == "Grandma":
        for taskString in traders.grandma:
            interface.trader.tasksCompleted.append(taskString)

    interface.UpdateTraderInfo()
    print("LOAD: Traders (%s) at %s" % [trader, savePath])


func SaveTaskNotes(task: TaskData, add: bool):
    if !FileAccess.file_exists(savePath + "Traders.tres"):
        return
    var traders = load(savePath + "Traders.tres") as TraderSave
    if add:
        if traders.taskNotes.size() == 0 || !traders.taskNotes.has(task):
            traders.taskNotes.append(task)
    if !add:
        if traders.taskNotes.has(task):
            traders.taskNotes.erase(task)
    ResourceSaver.save(traders, savePath + "Traders.tres")


func LoadTaskNotes() -> Array[TaskData]:
    if !FileAccess.file_exists(savePath + "Traders.tres"):
        return []
    var traders = load(savePath + "Traders.tres") as TraderSave
    return traders.taskNotes
