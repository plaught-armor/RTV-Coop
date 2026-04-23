## Mirrors saves between user:// (vanilla working dir) and user://coop/<id>/ or user://solo/.
extends RefCounted


const COOP_WORLDS_DIR: String = "user://coop/"
const SOLO_SAVES_DIR: String = "user://solo/"
const COOP_WORLD_SAVES: PackedStringArray = [
    "World.tres", "Cabin.tres", "Attic.tres", "Classroom.tres",
    "Tent.tres", "Bunker.tres", "Traders.tres",
]
const COOP_PLAYER_SAVE: String = "Character.tres"
# Persists across launches so a crash mid-session resumes the same world.
const COOP_ACTIVE_WORLD_FILE: String = "user://coop_active.txt"


var _cm: Node


func init_manager(manager: Node) -> void:
    _cm = manager


func set_active_world(activeWorldId: String) -> void:
    if is_instance_valid(_cm):
        _cm.worldId = activeWorldId
    var f: FileAccess = FileAccess.open(COOP_ACTIVE_WORLD_FILE, FileAccess.WRITE)
    if f != null:
        f.store_string(activeWorldId)
        f.close()


func get_active_world() -> String:
    if !FileAccess.file_exists(COOP_ACTIVE_WORLD_FILE):
        return ""
    var f: FileAccess = FileAccess.open(COOP_ACTIVE_WORLD_FILE, FileAccess.READ)
    if f == null:
        return ""
    var contents: String = f.get_as_text().strip_edges()
    f.close()
    return contents


func clear_active_world() -> void:
    if is_instance_valid(_cm):
        _cm.worldId = ""
    if FileAccess.file_exists(COOP_ACTIVE_WORLD_FILE):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(COOP_ACTIVE_WORLD_FILE))


## Host-only. Copies user://*.tres into the world dir after a save event.
func mirror_user_to_world() -> void:
    if !is_instance_valid(_cm):
        return
    if _cm.worldId.is_empty() || !_cm.isHost:
        return
    var worldDir: String = COOP_WORLDS_DIR + _cm.worldId + "/"
    DirAccess.make_dir_recursive_absolute(worldDir)
    var jobs: Array = []
    for saveName: String in COOP_WORLD_SAVES:
        var src: String = "user://" + saveName
        if FileAccess.file_exists(src):
            jobs.append([src, worldDir + saveName])
    var steamId: String = _cm.steamBridge.localSteamID if _cm.steamBridge.is_ready() else "local"
    if FileAccess.file_exists("user://" + COOP_PLAYER_SAVE):
        var playerDir: String = worldDir + "players/" + steamId + "/"
        DirAccess.make_dir_recursive_absolute(playerDir)
        jobs.append(["user://" + COOP_PLAYER_SAVE, playerDir + COOP_PLAYER_SAVE])
    if !jobs.is_empty():
        WorkerThreadPool.add_task(_run_copy_jobs.bind(jobs), false, "coop:mirror_user_to_world")


## Preloads world dir into user:// so vanilla Loader reads it as the regular save.
func mirror_world_to_user(forWorldId: String) -> void:
    var worldDir: String = COOP_WORLDS_DIR + forWorldId + "/"
    if !DirAccess.dir_exists_absolute(worldDir):
        return
    for saveName: String in COOP_WORLD_SAVES:
        var src: String = worldDir + saveName
        if FileAccess.file_exists(src):
            _copy_file(src, "user://" + saveName)
    var steamId: String = "local"
    if is_instance_valid(_cm) && _cm.steamBridge.is_ready():
        steamId = _cm.steamBridge.localSteamID
    var playerSrc: String = worldDir + "players/" + steamId + "/" + COOP_PLAYER_SAVE
    if FileAccess.file_exists(playerSrc):
        _copy_file(playerSrc, "user://" + COOP_PLAYER_SAVE)


## One-time migration: moves pre-mod user://*.tres into user://solo/ so coop doesn't wipe them.
func migrate_solo_saves_if_needed() -> int:
    if DirAccess.dir_exists_absolute(SOLO_SAVES_DIR):
        return 0
    if !FileAccess.file_exists("user://World.tres"):
        return 0
    DirAccess.make_dir_recursive_absolute(SOLO_SAVES_DIR)
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return 0
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    var migrated: int = 0
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            _copy_file("user://" + entry, SOLO_SAVES_DIR + entry)
            DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + entry))
            migrated += 1
        entry = dir.get_next()
    dir.list_dir_end()
    return migrated


func mirror_user_to_solo() -> void:
    if !FileAccess.file_exists("user://World.tres"):
        return
    DirAccess.make_dir_recursive_absolute(SOLO_SAVES_DIR)
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return
    var jobs: Array = []
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            jobs.append(["user://" + entry, SOLO_SAVES_DIR + entry])
        entry = dir.get_next()
    dir.list_dir_end()
    if !jobs.is_empty():
        WorkerThreadPool.add_task(_run_copy_jobs.bind(jobs), false, "coop:mirror_user_to_solo")


func mirror_solo_to_user() -> void:
    if !DirAccess.dir_exists_absolute(SOLO_SAVES_DIR):
        return
    var dir: DirAccess = DirAccess.open(SOLO_SAVES_DIR)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres"):
            _copy_file(SOLO_SAVES_DIR + entry, "user://" + entry)
        entry = dir.get_next()
    dir.list_dir_end()


## Removes all .tres from user:// except Validator/Preferences (mirrors Loader.NewGame's wipe).
func wipe_user_saves() -> void:
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return
    dir.list_dir_begin()
    var entry: String = dir.get_next()
    while entry != "":
        if entry.ends_with(".tres") && entry != "Validator.tres" && entry != "Preferences.tres":
            DirAccess.remove_absolute("user://" + entry)
        entry = dir.get_next()
    dir.list_dir_end()


func _copy_file(src: String, dst: String) -> void:
    var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
    # Empty read on failure: skip write so dst isn't truncated to 0 bytes.
    if bytes.is_empty():
        return
    var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
    if f != null:
        f.store_buffer(bytes)
        f.close()


# Worker thread: must not touch scene tree. FileAccess is thread-safe per handle.
func _run_copy_jobs(jobs: Array) -> void:
    for pair: Array in jobs:
        var src: String = pair[0]
        var dst: String = pair[1]
        var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
        if bytes.is_empty():
            continue
        var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
        if f != null:
            f.store_buffer(bytes)
            f.close()
