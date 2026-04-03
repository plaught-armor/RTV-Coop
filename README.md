# Vostok Multiplayer (VMP)

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/). Play the hardcore survival FPS with friends.

## Features

- **2-4 player co-op** via ENet networking with 20Hz position sync and interpolation
- **Steam integration** — lobbies, persona names, ownership verification, and NAT traversal via Steam Networking Sockets (no port forwarding needed)
- **World state sync** — doors, switches, time/weather synced between all players. Host-authoritative with client request/validation model
- **Synchronized map transitions** — both players transition together, spawn at the same location
- **Remote player audio** — footsteps, jumps, and landings play spatially at the remote player's position
- **Pickup sync** — host-authoritative item pickups prevent duplication
- **Zero game file modifications** — installs as a standard VostokMods `.vmz` archive
- **Optimized controller patch** — pooled audio, match-based footstep resolution, typed GameData access, collapsed input handling
- **Version safety** — MD5 hash check on all patched scripts; skips patches if game has updated
- **Ping overlay** — always-visible HUD showing connected players and round-trip times

## Installation

### From Release (recommended)

1. Install the [Metro Mod Loader](https://modworkshop.net/mod/48937) (recommended) or [VostokMods](https://github.com/Ryhon0/VostokMods)
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
cd mod/steam_helper
go build -o bin/steam_helper_linux -ldflags="-s -w" .

# Copy 64-bit Steam SDK lib next to the helper
cp "$(go env GOMODCACHE)/github.com/assemblaj/purego-steamworks@*/libsteam_api64.so" bin/libsteam_api.so

# Copy helper + lib to mod/bin for the mod to extract at runtime
mkdir -p ../bin
cp bin/steam_helper_linux bin/libsteam_api.so ../bin/
echo "2141300" > ../bin/steam_appid.txt

# Open the project in Godot 4.6+ and run
```

## Usage

### Controls

| Key | Action |
|-----|--------|
| **Insert** | Toggle multiplayer panel (host/join/disconnect/lobbies) |
| **F10** | Quick host |
| **F11** | Quick join localhost (debug builds only) |
| **F12** | Toggle player/ping HUD |
| **`** (backtick) | Toggle mouse capture (debug builds only) |

### Hosting (Steam — default)

1. Both players launch the game through Steam and load into a map
2. Host presses **Insert** → clicks "Host" (or **F10**)
3. Client presses **Insert** → clicks "Refresh" to see available lobbies → clicks to join
4. Connection is automatic via Steam relay — no IP or port forwarding needed

### Hosting (Direct Connect — debug only)

1. Both players load into a map
2. Host presses **F10** (or **Insert** → "Host")
3. Client presses **Insert**, enters host's IP in the "Direct Connect" section, clicks "Direct Join" (or **F11** for localhost)

## Architecture

```
mod/
├── autoload/coop_manager.gd       # Singleton: peers, patches, lifecycle
├── network/
│   ├── player_state.gd            # Position + footstep sync: 20Hz RPCs, interpolation
│   ├── world_state.gd             # World sync: doors, switches, transitions, pickups, sim
│   ├── steam_bridge.gd            # Steam helper IPC over localhost TCP
│   └── slot_serializer.gd         # SlotData <-> Dictionary for network transmission
├── patches/
│   ├── controller_patch.gd        # Movement broadcast, optimized input/audio/surface
│   ├── door_patch.gd              # Host-authoritative door interactions
│   ├── switch_patch.gd            # Host-authoritative switch interactions
│   ├── transition_patch.gd        # Synchronized map transitions
│   ├── pickup_patch.gd            # Host-authoritative item pickups
│   └── loot_container_patch.gd    # Container sync (disabled — TraderDisplay conflict)
├── presentation/
│   ├── remote_player.gd           # Ghost visual + spatial audio for remote players
│   └── remote_player.tscn
├── ui/
│   ├── coop_ui.gd                 # Multiplayer panel + lobby browser
│   └── coop_hud.gd                # Player list + ping overlay + keybind hints
├── steam_helper/                   # Go binary (separate process)
│   ├── main.go                    # TCP server, Steam init, lobby commands
│   └── tunnel.go                  # Steam Networking Sockets UDP relay
├── build.sh                       # Packages everything into .vmz
├── mod.txt                        # VostokMods manifest
└── README.md
```

**How it works:**
- The mod injects as a VostokMods autoload and patches game scripts via `take_over_path()`
- All patches verify script hashes before applying — skips if game has updated
- Position sync uses Godot's `@rpc` over `ENetMultiplayerPeer` at 20Hz with 100ms interpolation delay
- World state (doors, switches, pickups) is host-authoritative: clients send requests, host validates and broadcasts
- Map transitions are synchronized: host broadcasts to clients before transitioning, then teleports clients to host's spawn position
- Steam features (lobbies, ownership, NAT traversal) are handled by a Go helper binary communicating over localhost TCP
- For internet play, Steam Networking Sockets creates a transparent UDP tunnel — ENet connects to localhost while Steam handles relay/NAT
- All mod functions follow GDScript `snake_case` convention; only game overrides use PascalCase

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

## Compatibility

### Known Mod Conflicts

This mod patches the following scripts via `take_over_path`. Any other mod patching the same scripts will conflict — whichever loads last wins:

| Script | Patch | Conflict Risk |
|--------|-------|---------------|
| `Controller.gd` | Movement broadcast, optimized audio/input | High — Fly Mode, Immersive Overhaul |
| `Door.gd` | Host-authoritative door sync | Low |
| `Switch.gd` | Host-authoritative switch sync | Low |
| `Transition.gd` | Synchronized map transitions | Low |
| `Pickup.gd` | Host-authoritative pickups | Low |

### Game Version

The mod checks MD5 hashes of all patched scripts at startup. If a hash doesn't match (game updated), that patch is **skipped** to avoid crashes. Check the console for warnings.

## Roadmap

- [x] **Phase 1** — Position sync, ghost visuals, connection UI
- [x] **Steam** — Lobbies, persona names, ownership check, NAT traversal (P2P tunnel)
- [x] **Phase 2** — World state sync (doors, switches, simulation time/weather)
- [x] **Phase 2.5** — Transitions, pickups, footstep audio, serialization
- [ ] **Loot containers** — Deferred (TraderDisplay conflict needs resolution)
- [ ] **Phase 3** — AI multi-player awareness (enemies detect all players)
- [ ] **Phase 4** — Combat sync (weapon fire, hit registration, damage)
- [ ] **Third-person model** — Replace ghost capsule with Bandit mesh
- [ ] **Voice chat** — Steam Voice API or external (Discord)

## Requirements

- [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/) (Steam)
- [Metro Mod Loader](https://modworkshop.net/mod/48937) (recommended) or [VostokMods](https://github.com/Ryhon0/VostokMods)
- Steam running (for lobbies and ownership verification)

## Credits

- **Game:** [Road to Vostok](https://roadtovostok.com/) by Antti Väre
- **Mod Loaders:** [VostokMods](https://github.com/Ryhon0/VostokMods) by Ryhon0, [Metro Mod Loader](https://modworkshop.net/mod/48937) by the RTV modding community
- **Steam Bindings:** [purego-steamworks](https://github.com/assemblaj/purego-steamworks) by assemblaj

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
