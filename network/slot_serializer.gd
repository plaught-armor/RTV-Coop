## Serializes [SlotData] to/from [Dictionary] for network transmission.
## Uses [code]itemData.resource_path[/code] to identify items across peers.
## Both peers have the same game resources, so paths resolve identically.
class_name SlotSerializer
extends RefCounted

## Allowed resource path prefixes for [method load] calls. Rejects arbitrary paths.
const ALLOWED_PREFIXES: PackedStringArray = [
	"res://Items/",
	"res://Loot/",
]


## Converts a [SlotData] to a [Dictionary] suitable for RPC transmission.
## Returns empty dict for null/invalid slots (preserved as-is in arrays).
static func Pack(slot: SlotData) -> Dictionary:
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
	# Nested attachments (Array[ItemData] → PackedStringArray, preserve nulls as "")
	var nestedPaths: PackedStringArray = []
	for attachment: ItemData in slot.nested:
		nestedPaths.append(attachment.resource_path if attachment != null else "")
	data[&"nested"] = nestedPaths

	# Recursive storage (Array[SlotData] → Array[Dictionary])
	if slot.storage.size() > 0:
		var packedStorage: Array[Dictionary] = []
		for stored: SlotData in slot.storage:
			packedStorage.append(Pack(stored))
		data[&"storage"] = packedStorage

	return data


## Reconstructs a [SlotData] from a packed [Dictionary].
## Returns null for empty/invalid dicts.
static func Unpack(data: Dictionary) -> SlotData:
	if data.is_empty():
		return null
	var itemPath: String = data.get(&"item_path", "")
	if !IsAllowedPath(itemPath):
		return null
	var itemRes: Resource = load(itemPath)
	if !(itemRes is ItemData):
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

	# Nested attachments (preserve null entries for slot index stability)
	var nestedPaths: PackedStringArray = data.get(&"nested", PackedStringArray())
	for path: String in nestedPaths:
		if path.is_empty():
			slot.nested.append(null)
		elif IsAllowedPath(path):
			var attachment: Resource = load(path)
			slot.nested.append(attachment if attachment is ItemData else null)
		else:
			slot.nested.append(null)

	# Recursive storage
	var packedStorage: Array = data.get(&"storage", [])
	for storedData: Dictionary in packedStorage:
		slot.storage.append(Unpack(storedData))

	return slot


## Packs an array of [SlotData]. Null entries become empty dicts (preserved).
static func PackArray(slots: Array[SlotData]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot: SlotData in slots:
		result.append(Pack(slot))
	return result


## Unpacks an array of [Dictionary]. Empty dicts become null (preserved to keep indices stable).
static func UnpackArray(dataArray: Array[Dictionary]) -> Array[SlotData]:
	var result: Array[SlotData] = []
	for data: Dictionary in dataArray:
		result.append(Unpack(data))
	return result


## Returns true if the path starts with an allowed prefix.
static func IsAllowedPath(path: String) -> bool:
	if path.is_empty():
		return false
	for prefix: String in ALLOWED_PREFIXES:
		if path.begins_with(prefix):
			return true
	return false
