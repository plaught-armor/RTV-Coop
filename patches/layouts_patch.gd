## Patch for [code]Layouts.gd[/code] — deterministic room layouts in co-op.
##
## Overrides:
## [br]- [method _ready]: uses seeded random based on node path so host and
##   client pick the same layout for each Layouts node in the scene.
##
## Without this, each client picks a random layout independently, causing
## structural desync (different rooms, missing walls, wrong geometry).
## Original behaviour is 100% preserved when not in a co-op session.
extends "res://Scripts/Layouts.gd"


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

    # Seed from node path hash so every client picks the same layout.
    var pathHash: int = str(get_path()).hash()
    var childCount: int = get_child_count()
    if childCount == 0:
        return
    var pick: int = absi(pathHash) % childCount

    layout = get_child(pick)
    layout.show()

    for child: Node3D in get_children():
        if child != layout:
            child.queue_free()
