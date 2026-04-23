## Packs/unpacks SlotData over RPC using resource_path as the cross-peer item key.
extends RefCounted

# var (not const): const PackedArray mutation bug (Godot #88753).
var ALLOWED_PREFIXES: PackedStringArray = PackedStringArray(["res://Items/", "res://Loot/"])

# Skips path-validation + typecheck on repeated unpacks (inventories hit 10-50 items/call).
var _itemCache: Dictionary[String, Resource] = {}


## Returns null if path is disallowed or resource isn't an ItemData.
func _resolve_item(path: String) -> Resource:
    var cached: Resource = null
    if _itemCache.has(path):
        cached = _itemCache[path]
    if cached != null:
        return cached
    if !is_allowed_path(path):
        return null
    var res: Resource = load(path)
    if !(res is ItemData):
        return null
    _itemCache[path] = res
    return res


## Returns empty dict for null/invalid slots (preserved as-is in arrays).
func pack(slot: SlotData) -> Dictionary:
    if slot == null || slot.itemData == null:
        return { }
    var data: Dictionary = {
        &"item_path": slot.itemData.resource_path,
        &"condition": slot.condition,
        &"amount": slot.amount,
        &"position": slot.position,
        &"mode": slot.mode,
        &"zoom": slot.zoom,
        &"chamber": slot.chamber,
        &"casing": slot.casing,
        &"state": slot.state,
    }
    # Array[ItemData] -> PackedStringArray; preserve null entries as "".
    var nestedPaths: PackedStringArray = []
    for attachment: ItemData in slot.nested:
        nestedPaths.append(attachment.resource_path if attachment != null else "")
    data[&"nested"] = nestedPaths

    if slot.storage.size() > 0:
        var packedStorage: Array[Dictionary] = []
        for stored: SlotData in slot.storage:
            packedStorage.append(pack(stored))
        data[&"storage"] = packedStorage

    return data


## Returns null for empty/invalid dicts.
func unpack(data: Dictionary) -> SlotData:
    if data.is_empty():
        return null
    var itemPath: String = data.get(&"item_path", "")
    var itemRes: Resource = _resolve_item(itemPath)
    if itemRes == null:
        return null

    var slot: SlotData = SlotData.new()
    slot.itemData = itemRes
    slot.condition = data.get(&"condition", 100)
    slot.amount = data.get(&"amount", 0)
    slot.position = data.get(&"position", 0)
    slot.mode = data.get(&"mode", 1)
    slot.zoom = data.get(&"zoom", 1)
    slot.chamber = data.get(&"chamber", false)
    slot.casing = data.get(&"casing", false)
    slot.state = data.get(&"state", "")

    # Null entries preserved to keep slot indices stable.
    var nestedPaths: PackedStringArray = data.get(&"nested", PackedStringArray())
    for path: String in nestedPaths:
        if path.is_empty():
            slot.nested.append(null)
        else:
            slot.nested.append(_resolve_item(path))

    var packedStorage: Array = data.get(&"storage", [])
    for storedData: Dictionary in packedStorage:
        slot.storage.append(unpack(storedData))

    return slot


func pack_array(slots: Array[SlotData]) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for slot: SlotData in slots:
        result.append(pack(slot))
    return result


func unpack_array(dataArray: Array[Dictionary]) -> Array[SlotData]:
    var result: Array[SlotData] = []
    for data: Dictionary in dataArray:
        result.append(unpack(data))
    return result


func is_allowed_path(path: String) -> bool:
    if path.is_empty():
        return false
    for prefix: String in ALLOWED_PREFIXES:
        if path.begins_with(prefix):
            return true
    return false
