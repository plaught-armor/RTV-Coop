## Registers every mod patch via take_over_path.
extends RefCounted


# Flat [orig_path, patch_path, ...]: Godot 4 can't type-coerce nested Array literals.
# Only scripts on vostok-mod-loader's runtime-sensitive skip-list (Mine.gd,
# Explosion.gd, ParticleInstance, MuzzleFlash, Hit, TreeRenderer, Message)
# stay on take_over_path; everything else uses the hook API.
const PATCHES: Array[String] = [
    "res://Scripts/Explosion.gd",     "res://mod/patches/explosion_patch.gd",
    "res://Scripts/Mine.gd",          "res://mod/patches/mine_patch.gd",
]


## Loads, reloads, and hot-swaps every patched script; call once at mod boot.
## Entries whose orig_path appears in `skip` are bypassed — typically because
## the caller registered hook-API callbacks against that script via RTVModLib.
func register_all(skip: PackedStringArray = []) -> int:
    var count: int = 0
    var i: int = 0
    while i < PATCHES.size():
        var origPath: String = PATCHES[i]
        var patchPath: String = PATCHES[i + 1]
        if skip.has(origPath):
            i += 2
            continue
        var patch: Script = load(patchPath)
        if patch != null:
            patch.reload()
            patch.take_over_path(origPath)
            count += 1
        else:
            push_error("[patch_registry] failed to load %s" % patchPath)
        i += 2
    return count
