extends RefCounted
## Snapshots user://logs into a timestamped dir and opens it; heavy I/O on WorkerThreadPool.

signal logs_collected(absDir: String, fileCount: int)


func collect() -> void:
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var snapDir: String = "user://rtv-coop-logs/%s/" % stamp
	DirAccess.make_dir_recursive_absolute(snapDir)

	var sources: PackedStringArray = [
		"user://logs/godot.log",
		"user://logs/steam_helper.log",
	]
	# Pick last three timestamped rollover logs (godot<timestamp>.log).
	var logsDir: DirAccess = DirAccess.open("user://logs/")
	if logsDir != null:
		var candidates: Array[String] = []
		logsDir.list_dir_begin()
		var entry: String = logsDir.get_next()
		while entry != "":
			if entry.ends_with(".log") && entry != "godot.log" && entry != "steam_helper.log":
				candidates.append(entry)
			entry = logsDir.get_next()
		logsDir.list_dir_end()
		candidates.sort()
		for i: int in range(max(0, candidates.size() - 3), candidates.size()):
			sources.append("user://logs/" + candidates[i])

	var info: Dictionary = {
		"stamp": stamp,
		"os": OS.get_name(),
		"godot": Engine.get_version_info().string,
	}
	WorkerThreadPool.add_task(
		_run_snapshot.bind(snapDir, sources, info),
		false,
		"coop:collect_logs",
	)


# Worker-thread body; defers main-thread callback so shell_open runs on the scene tree.
func _run_snapshot(snapDir: String, sources: PackedStringArray, info: Dictionary) -> void:
	var copied: int = 0
	for src: String in sources:
		if !FileAccess.file_exists(src):
			continue
		var dst: String = snapDir + src.get_file()
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
		if bytes.is_empty():
			continue
		var outFile: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
		if outFile != null:
			outFile.store_buffer(bytes)
			outFile.close()
			copied += 1
	var infoFile: FileAccess = FileAccess.open(snapDir + "info.txt", FileAccess.WRITE)
	if infoFile != null:
		infoFile.store_line("RTV Co-op Mod log snapshot")
		infoFile.store_line("Timestamp: %s" % info.get(&"stamp", ""))
		infoFile.store_line("OS: %s" % info.get(&"os", ""))
		infoFile.store_line("Godot: %s" % info.get(&"godot", ""))
		infoFile.store_line("Files: %d" % copied)
		infoFile.close()
	_on_snapshot_done.call_deferred(snapDir, copied)


func _on_snapshot_done(snapDir: String, copied: int) -> void:
	var absDir: String = ProjectSettings.globalize_path(snapDir)
	print("[logs] snapshot: %s (%d files)" % [absDir, copied])
	OS.shell_open(absDir)
	logs_collected.emit(absDir, copied)
