# Vostok Multiplayer (VMP)

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/). Play the hardcore survival FPS with friends.

> **Status:** Phase 1 — players can see each other and move together. World state sync (doors, loot, AI) is in progress.

## Features

- **2-4 player co-op** via ENet networking with 20Hz position sync and interpolation
- **Steam integration** — lobbies, persona names, ownership verification, and NAT traversal via Steam Networking Sockets (no port forwarding)
- **Zero game file modifications** — installs as a standard VostokMods `.vmz` archive
- **Optimized controller patch** — pooled audio, match-based footstep resolution, typed GameData access, collapsed input handling
- **Ping overlay** — always-visible HUD showing connected players and round-trip times (F12 to toggle)

## Installation

### From Release (recommended)

1. Install [VostokMods](https://github.com/Ryhon0/VostokMods) or the Metro Mod Loader
2. Download `rtv-coop.vmz` from the [Releases](https://github.com/plaught-armor/mod/releases) page
3. Place `rtv-coop.vmz` in the game's `mods/` folder:
   - **Windows:** `%APPDATA%\Road to Vostok Demo\mods\`
   - **Linux:** `~/.local/share/Road to Vostok Demo/mods/`
4. Launch the game through Steam

### From Source (development)

```bash
# Clone into the decompiled game directory
cd "/path/to/Road to Vostok Demo"
git clone https://github.com/plaught-armor/mod.git mod

# Add the autoload to project.godot (before the game's autoloads):
# CoopManager="*res://mod/autoload/coop_manager.gd"

# Build the Steam helper (requires Go 1.21+)
cd steam_helper
go build -o bin/steam_helper_linux -ldflags="-s -w" .

# Copy Steam SDK lib next to the helper
cp "$(go env GOMODCACHE)/github.com/assemblaj/purego-steamworks@*/libsteam_api.so" bin/
ln -s libsteam_api64.so bin/libsteam_api.so  # if 64-bit version

# Open the project in Godot 4.6+ and run
```

## Usage

### Hosting (LAN / Direct)

1. Both players load into a map (not the main menu)
2. Host presses **F10** (or opens panel with **F9** → "Host")
3. Client presses **F9**, enters host's IP, and clicks "Join" (or **F11** for localhost)

### Hosting (Steam)

1. Both players launch the game through Steam
2. Host presses **F10** — creates a Steam lobby (friends-only)
3. Client presses **F9** → "Refresh" to see available lobbies → clicks to join
4. Connection is automatic via Steam relay — no IP or port forwarding needed

### Controls

| Key | Action |
|-----|--------|
| **F9** | Toggle co-op panel (host/join/disconnect) |
| **F10** | Quick host |
| **F11** | Quick join (localhost in ENet mode) |
| **F12** | Toggle player/ping HUD |
| **`** (backtick) | Toggle mouse capture (debug builds only) |

## Architecture

```
mod/
├── autoload/coop_manager.gd    # Singleton: peers, patches, lifecycle
├── network/
│   ├── player_state.gd         # Position sync: 20Hz RPCs, interpolation
│   └── steam_bridge.gd         # Steam helper IPC over localhost TCP
├── patches/
│   └── controller_patch.gd     # Extends Controller.gd via take_over_path
├── presentation/
│   ├── remote_player.gd        # Ghost capsule visual for remote players
│   └── remote_player.tscn
└── ui/
    ├── coop_ui.gd              # Host/join panel + lobby browser
    └── coop_hud.gd             # Player list + ping overlay

steam_helper/                    # Go binary (separate process)
├── main.go                     # TCP server, Steam init, lobby commands
└── tunnel.go                   # Steam Networking Sockets UDP relay
```

**How it works:**
- The mod injects as a VostokMods autoload and patches game scripts via `take_over_path()`
- Position sync uses Godot's built-in `@rpc` over `ENetMultiplayerPeer`
- Steam features (lobbies, ownership, NAT traversal) are handled by a Go helper binary communicating over localhost TCP
- For internet play, Steam Networking Sockets creates a transparent UDP tunnel — ENet thinks it's talking to localhost while Steam handles relay/NAT

## Building

```bash
# Package as .vmz for distribution
cd mod
./build.sh

# Cross-compile Steam helper for Windows
cd steam_helper
GOOS=windows GOARCH=amd64 go build -o bin/steam_helper.exe -ldflags="-s -w" .
```

The build script copies the Steam helper binaries and `libsteam_api` into `mod/bin/` and packages everything into `rtv-coop.vmz`.

## Roadmap

- [x] **Phase 1** — Position sync, ghost visuals, connection UI
- [x] **Steam** — Lobbies, persona names, ownership check, NAT traversal
- [ ] **Phase 2** — World state sync (doors, loot containers, pickups, time/weather)
- [ ] **Phase 3** — AI multi-player awareness (enemies detect all players)
- [ ] **Phase 4** — Combat sync (weapon fire, hit registration, damage)

## Requirements

- [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/) (Steam)
- [VostokMods](https://github.com/Ryhon0/VostokMods) or Metro Mod Loader
- Steam running (for Steam features)

## Credits

- **Game:** [Road to Vostok](https://roadtovostok.com/) by Antti Väre
- **Mod Loader:** [VostokMods](https://github.com/Ryhon0/VostokMods) by Ryhon0
- **Steam Bindings:** [purego-steamworks](https://github.com/assemblaj/purego-steamworks) by assemblaj

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
