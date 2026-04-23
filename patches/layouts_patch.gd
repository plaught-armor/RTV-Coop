extends "res://Scripts/Layouts.gd"
## Patch for Layouts.gd — deterministic room pick from path hash so all peers match.


func _ready() -> void:
	var cm: Node = null
	var root: Node = get_tree().root if get_tree() != null else null
	if root != null:
		for child: Node in root.get_children():
			if child.has_meta(&"is_coop_manager"):
				cm = child
				break

	if cm == null || !cm.is_session_active():
		super._ready()
		return

	var pathHash: int = get_path().hash()
	var childCount: int = get_child_count()
	if childCount == 0:
		return
	var pick: int = absi(pathHash) % childCount

	layout = get_child(pick)
	layout.show()

	for child: Node3D in get_children():
		if child != layout:
			child.queue_free()
