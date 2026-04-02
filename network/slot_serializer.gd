## Serializes [SlotData] to/from [Dictionary] for network transmission.
## Uses [code]itemData.resource_path[/code] to identify items across peers.
## Both peers have the same game resources, so paths resolve identically.
class_name SlotSerializer
extends RefCounted

## Converts a [SlotData] to a [Dictionary] suitable for RPC transmission.
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
	# Serialize nested attachments (Array[ItemData] → Array[String])
	var nestedPaths: PackedStringArray = []
	for attachment: ItemData in slot.nested:
		if attachment != null:
			nestedPaths.append(attachment.resource_path)
	data[&"nested"] = nestedPaths
	return data


## Reconstructs a [SlotData] from a packed [Dictionary].
static func Unpack(data: Dictionary) -> SlotData:
	if data.is_empty():
		return null
	var itemPath: String = data.get(&"item_path", "")
	if itemPath.is_empty():
		return null
	var itemRes: Resource = load(itemPath)
	if itemRes == null || !(itemRes is ItemData):
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

	# Reconstruct nested attachments
	var nestedPaths: PackedStringArray = data.get(&"nested", [])
	for path: String in nestedPaths:
		var attachment: Resource = load(path)
		if attachment is ItemData:
			slot.nested.append(attachment)

	return slot


## Packs an array of [SlotData] into an array of [Dictionary].
static func PackArray(slots: Array) -> Array:
	var result: Array = []
	for slot in slots:
		result.append(Pack(slot))
	return result


## Unpacks an array of [Dictionary] into an array of [SlotData].
static func UnpackArray(dataArray: Array) -> Array[SlotData]:
	var result: Array[SlotData] = []
	for data: Dictionary in dataArray:
		var slot: SlotData = Unpack(data)
		if slot != null:
			result.append(slot)
	return result
