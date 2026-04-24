## Registers every mod patch via take_over_path.
extends RefCounted


# Flat [orig_path, patch_path, ...]: Godot 4 can't type-coerce nested Array literals.
#
# ORDER MATTERS: when a patch's `extends` clause parses its base script, any
# const/var preloads in that base run immediately, baking ExtResource refs into
# PackedScenes before take_over_path gets called. Dependencies must therefore
# be patched BEFORE their dependents so the dependents' preloads pick up the
# patched script from ResourceCache.
#
# Known dependency chains:
#   AISpawner.gd preloads AI_Bandit/Guard/Military/Punisher.tscn -> AI.gd
#   EventSystem.gd preloads Helicopter/CASA/BTR/Police/Rescue.tscn ->
#     Helicopter.gd, CASA.gd, BTR.gd, Police.gd
const PATCHES: Array[String] = [
    # Leaves first (no mod dependencies, or depended-upon by later patches).
    "res://Scripts/AI.gd",            "res://mod/patches/ai_patch.gd",
    "res://Scripts/Helicopter.gd",    "res://mod/patches/helicopter_patch.gd",
    "res://Scripts/CASA.gd",          "res://mod/patches/casa_patch.gd",
    "res://Scripts/BTR.gd",           "res://mod/patches/btr_patch.gd",
    "res://Scripts/Police.gd",        "res://mod/patches/police_patch.gd",
    # Dependents (preload scenes that reference the above).
    "res://Scripts/AISpawner.gd",     "res://mod/patches/ai_spawner_patch.gd",
    "res://Scripts/EventSystem.gd",   "res://mod/patches/event_system_patch.gd",
    # Remainder — order-independent.
    "res://Scripts/Controller.gd",    "res://mod/patches/controller_patch.gd",
    "res://Scripts/Interactor.gd",    "res://mod/patches/interactor_patch.gd",
    "res://Scripts/Transition.gd",    "res://mod/patches/transition_patch.gd",
    "res://Scripts/Pickup.gd",        "res://mod/patches/pickup_patch.gd",
    "res://Scripts/Interface.gd",     "res://mod/patches/interface_patch.gd",
    "res://Scripts/LootSimulation.gd", "res://mod/patches/loot_simulation_patch.gd",
    "res://Scripts/GrenadeRig.gd",    "res://mod/patches/grenade_rig_patch.gd",
    "res://Scripts/KnifeRig.gd",      "res://mod/patches/knife_rig_patch.gd",
    "res://Scripts/Explosion.gd",     "res://mod/patches/explosion_patch.gd",
    "res://Scripts/Character.gd",     "res://mod/patches/character_patch.gd",
    "res://Scripts/Mine.gd",          "res://mod/patches/mine_patch.gd",
    "res://Scripts/Loader.gd",        "res://mod/patches/loader_patch.gd",
    "res://Scripts/Settings.gd",      "res://mod/patches/settings_patch.gd",
    "res://Scripts/Furniture.gd",     "res://mod/patches/furniture_patch.gd",
    "res://Scripts/FishPool.gd",      "res://mod/patches/fish_pool_patch.gd",
    "res://Scripts/DecorMode.gd",     "res://mod/patches/decor_mode_patch.gd",
    "res://Scripts/RocketGrad.gd",    "res://mod/patches/rocket_grad_patch.gd",
    "res://Scripts/RocketHelicopter.gd", "res://mod/patches/rocket_helicopter_patch.gd",
    "res://Scripts/MissileSpawner.gd", "res://mod/patches/missile_spawner_patch.gd",
    "res://Scripts/Radio.gd",         "res://mod/patches/radio_patch.gd",
    "res://Scripts/Television.gd",    "res://mod/patches/television_patch.gd",
    "res://Scripts/Instrument.gd",    "res://mod/patches/instrument_patch.gd",
]


## Loads, reloads, and hot-swaps every patched script; call once at mod boot.
func register_all() -> int:
    var count: int = PATCHES.size() >> 1
    var i: int = 0
    while i < PATCHES.size():
        var origPath: String = PATCHES[i]
        var patchPath: String = PATCHES[i + 1]
        var patch: Script = load(patchPath)
        if patch != null:
            patch.reload()
            patch.take_over_path(origPath)
        else:
            push_error("[patch_registry] failed to load %s" % patchPath)
        i += 2
    return count
