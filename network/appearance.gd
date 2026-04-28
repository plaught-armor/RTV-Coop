## Appearance registry and appearance.json sidecar (CharacterSave can't be extended).
extends RefCounted


# Only rigged items render on remotes; other roots are invisible or missing bones.
const ALLOWED_VISUAL_ROOTS: Array[String] = [
    "res://Items/Weapons/",
    "res://Items/Backpacks/",
]


func is_visually_allowed(resourcePath: String) -> bool:
    for root: String in ALLOWED_VISUAL_ROOTS:
        if resourcePath.begins_with(root):
            return true
    return false


const ALLOWED_BODIES: Array[String] = ["Capsule"]

# Capsule body has no skinned mesh — uses a literal sentinel so the material
# slot still validates against the same allowlist as legacy AI-rig peers did.
const CAPSULE_MATERIAL_SENTINEL: String = "res://AI/_capsule"

const OPTIONS: Array = [
    {"name": "Capsule (FPS Arms)", "body": "Capsule", "material": CAPSULE_MATERIAL_SENTINEL},
]


func get_defaults() -> Dictionary:
    return {"body": OPTIONS[0].body, "material": OPTIONS[0].material}


func is_allowed_material(p: String) -> bool:
    return p == CAPSULE_MATERIAL_SENTINEL


func is_valid(entry: Dictionary) -> bool:
    var b: String = entry.get("body", "")
    var t: String = entry.get("material", "")
    if !(b in ALLOWED_BODIES):
        return false
    return is_allowed_material(t)


func sanitize(entry: Dictionary) -> Dictionary:
    if is_valid(entry):
        return {"body": entry.body, "material": entry.material}
    return get_defaults()


func file_path(playerSaveDir: String) -> String:
    if !playerSaveDir.ends_with("/"):
        playerSaveDir += "/"
    return playerSaveDir + "appearance.json"


## Returns null on missing/corrupt file so callers distinguish "pick now" from "use saved".
func load_from(playerSaveDir: String) -> Variant:
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


func save_to(playerSaveDir: String, entry: Dictionary) -> bool:
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
