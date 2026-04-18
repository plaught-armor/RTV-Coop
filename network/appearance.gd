## Player appearance registry + per-world sidecar storage for co-op.
## Base-game [CharacterSave] is authored by the solo-game [Loader] and can't
## be safely extended; appearance rides alongside as appearance.json.
extends RefCounted


const SUPER_RIG_PATH: String = "res://mod/presentation/rigs/super_rig.scn"

## Only items under these roots render on remote players — everything else
## isn't rigged or is invisible by design.
const ALLOWED_VISUAL_ROOTS: Array[String] = [
    "res://Items/Weapons/",
    "res://Items/Backpacks/",
]


static func is_visually_allowed(resourcePath: String) -> bool:
    for root: String in ALLOWED_VISUAL_ROOTS:
        if resourcePath.begins_with(root):
            return true
    return false


const ALLOWED_BODIES: Array[String] = ["Bandit", "Guard", "Military", "Punisher"]

## Material paths must resolve under this prefix so remote peers can't smuggle
## arbitrary resource loads through the appearance RPC.
const MATERIAL_PREFIX: String = "res://AI/"

const OPTIONS: Array = [
    {"name": "Bandit 01", "body": "Bandit", "material": "res://AI/Bandit/Files/MT_Bandit_01.tres"},
    {"name": "Bandit 02", "body": "Bandit", "material": "res://AI/Bandit/Files/MT_Bandit_02.tres"},
    {"name": "Bandit 03", "body": "Bandit", "material": "res://AI/Bandit/Files/MT_Bandit_03.tres"},
    {"name": "Bandit 04", "body": "Bandit", "material": "res://AI/Bandit/Files/MT_Bandit_04.tres"},
    {"name": "Guard", "body": "Guard", "material": "res://AI/Guard/Files/MT_Guard.tres"},
    {"name": "Military", "body": "Military", "material": "res://AI/Military/Files/MT_Military.tres"},
    {"name": "Punisher", "body": "Punisher", "material": "res://AI/Punisher/Files/MT_Punisher.tres"},
]


static func get_defaults() -> Dictionary:
    return {"body": OPTIONS[0].body, "material": OPTIONS[0].material}


static func is_allowed_material(p: String) -> bool:
    if p.is_empty():
        return false
    if p.find("..") != -1:
        return false
    return p.begins_with(MATERIAL_PREFIX)


static func is_valid(entry: Dictionary) -> bool:
    var b: String = entry.get("body", "")
    var t: String = entry.get("material", "")
    if !(b in ALLOWED_BODIES):
        return false
    return is_allowed_material(t)


static func sanitize(entry: Dictionary) -> Dictionary:
    if is_valid(entry):
        return {"body": entry.body, "material": entry.material}
    return get_defaults()


static func file_path(playerSaveDir: String) -> String:
    if !playerSaveDir.ends_with("/"):
        playerSaveDir += "/"
    return playerSaveDir + "appearance.json"


## Returns null (not defaults) when the file is missing or corrupt so callers
## can distinguish "pick now" from "use saved".
static func load_from(playerSaveDir: String) -> Variant:
    var path: String = file_path(playerSaveDir)
    if !FileAccess.file_exists(path):
        return null
    var f: FileAccess = FileAccess.open(path, FileAccess.READ)
    if f == null:
        return null
    var text: String = f.get_as_text()
    f.close()
    var parsed: Variant = JSON.parse_string(text)
    if !(parsed is Dictionary):
        return null
    if !is_valid(parsed):
        return null
    return {"body": parsed.body, "material": parsed.material}


static func save_to(playerSaveDir: String, entry: Dictionary) -> bool:
    if !is_valid(entry):
        return false
    DirAccess.make_dir_recursive_absolute(playerSaveDir)
    var path: String = file_path(playerSaveDir)
    var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        return false
    f.store_string(JSON.stringify({"body": entry.body, "material": entry.material}))
    f.close()
    return true
