# Vostok Multiplayer (VMP)

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/). Play the hardcore survival FPS with up to 4 friends.

## Features

- **2-4 player co-op** via ENet networking with 20Hz position sync and interpolation
- **Steam integration** -- lobby browser, friend invites with avatars, persona names
- **World state sync** -- doors, switches, time/weather synced between all players
- **Synchronized map transitions** -- all players transition together
- **Remote player audio** -- footsteps, jumps, and landings play spatially
- **Host-authoritative pickups** -- prevents item duplication
- **Zero game file modifications** -- installs as a `.vmz` mod archive
- **Version safety** -- MD5 hash check on patched scripts; warns if game has updated
- **Ping overlay** -- always-visible HUD showing connected players, avatars, and round-trip times

---

## Installation

### Requirements

- [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/) (Steam)
- [Metro Mod Loader](https://modworkshop.net/mod/48937)
- Steam running (required for multiplayer features)

### Windows

1. Install the [Metro Mod Loader](https://modworkshop.net/mod/48937) following its instructions
2. Download `rtv-coop.vmz` from the [Releases](https://github.com/plaught-armor/mod/releases) page
3. Place `rtv-coop.vmz` in the game's `mods/` folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok Demo\mods\
   ```
   > Your Steam library path may differ. Right-click the game in Steam > Manage > Browse Local Files, then place the file in the `mods/` subfolder.
4. Launch the game through Steam
5. The mod loads automatically -- you should see **INS Multiplayer** in the top-right corner

### Linux (Proton)

Road to Vostok is a Windows game. On Linux it runs through Proton (Steam's Wine-based compatibility layer). The mod fully supports this.

1. Install the [Metro Mod Loader](https://modworkshop.net/mod/48937)
2. Download `rtv-coop.vmz` from Releases
3. Place it in the game's `mods/` folder:
   ```
   ~/.local/share/Steam/steamapps/common/Road to Vostok Demo/mods/
   ```
4. Launch the game through Steam
5. The mod auto-detects Proton and launches the Steam helper inside the Wine prefix
6. You should see **INS Multiplayer** in the top-right corner once Steam connects

### Linux (Native Godot)

If you're running the decompiled project natively in the Godot editor:

1. Place the `mod/` folder inside the project directory
2. Add the autoload to `project.godot`:
   ```ini
   [autoload]
   CoopManager="*res://mod/autoload/coop_manager.gd"
   ```
3. Run from the editor -- debug mode enables automatically (windowed mode, verbose logging, direct connect UI)

### Verifying Installation

Once in-game and loaded into a map:
- **Top-right corner** should show `INS Multiplayer` (or a Steam connection status message)
- Press **INS** (Insert) to open the multiplayer panel
- The panel should show Host, Refresh, and Invite buttons

---

## Usage

### Controls

| Key | Action |
|-----|--------|
| **INS** (Insert) | Toggle multiplayer panel |
| **F10** | Quick host |
| **F12** | Toggle player/ping HUD |

Editor-only debug keys:

| Key | Action |
|-----|--------|
| **F11** | Quick join localhost |
| **\`** (backtick) | Toggle mouse capture |

### Hosting a Game

1. Load into a map (start a new game or load a save)
2. Press **INS** to open the multiplayer panel
3. Click **Host** (or press **F10**)
4. You are now hosting -- other players can see your lobby

### Joining a Game

1. Load into any map
2. Press **INS** to open the multiplayer panel
3. Click **Refresh** to see available Steam lobbies
4. Click a lobby to join

### Inviting Friends

1. Host a game first
2. Press **INS** to open the multiplayer panel
3. Click **Invite** to see your online Steam friends with profile pictures
4. Click **Invite** next to a friend's name to send them a Steam game invite

### Disconnecting

Press **INS** and click **Disconnect**, or close the game.

---

## Troubleshooting

### "Steam: offline" on the HUD

The Steam helper binary couldn't connect. Common causes:
- **Steam is not running.** Launch Steam before the game.
- **First launch.** The helper binary is extracted on first run. Restart the game if it didn't connect the first time.
- **Proton prefix corrupted.** Delete the prefix and relaunch:
  ```
  rm -rf ~/.local/share/Steam/steamapps/compatdata/2141300/
  ```

### Where are the logs?

- **Windows:** `%APPDATA%\Road to Vostok Demo\logs\godot.log`
- **Linux (Proton):** `~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok Demo/logs/godot.log`
- **Linux (Native):** `~/.local/share/godot/app_userdata/Road to Vostok/logs/godot.log`

Look for `[SteamBridge]` and `[CoopManager]` lines to diagnose issues.

### Mouse stuck / can't look around

Press **INS** to close the multiplayer panel. The panel captures the mouse when open.

### "Hash mismatch" warnings in console

The game was updated and a patched script changed. The patch still applies but may cause issues. Check for a mod update that matches the new game version.

### Can't see other player

Both players must be on the same map. Remote players appear as translucent green capsules. If you transitioned to a different map, the other player needs to transition too (transitions are synced when hosted).

### Invite button doesn't show friends

You must be hosting a game first (click Host before Invite). The friend list only shows friends who are currently online.

---

## How It Works

### Mod Loading

The mod is packaged as a `.vmz` archive (ZIP) loaded by the Metro Mod Loader at startup via Godot's `load_resource_pack()`. The mod loader reads `mod.txt` from the archive, registers the `CoopManager` autoload, and all mod scripts become available under `res://mod/`.

### Script Patching

Game scripts are patched using Godot's `take_over_path()`. Each patch extends the original script and overrides specific methods to add networking hooks. Original behavior is preserved via `super.Method()` calls. All patches verify MD5 hashes at startup and log a warning if the game has been updated.

| Script | What's Patched |
|--------|----------------|
| `Controller.gd` | Position broadcast, optimized input/audio/surface detection |
| `Door.gd` | Host-authoritative door open/close |
| `Switch.gd` | Host-authoritative switch toggle |
| `Transition.gd` | Synchronized map transitions |
| `Pickup.gd` | Host-authoritative item pickups |

### Networking Model

- **Host/Client** via `ENetMultiplayerPeer` (no dedicated server)
- **Host is authoritative** for world state, loot, and damage
- **Clients own** their local movement and input
- Position sync: unreliable RPCs at 20Hz with 100ms interpolation buffer
- World state: reliable RPCs with request/validate/broadcast pattern

### Steam Helper

A Go binary (`steam_helper`) runs alongside the game, communicating via localhost TCP with a JSON protocol. It provides:
- Steam user identity and persona name
- Lobby creation, discovery, and joining
- Friend list with online status and 32x32 avatars
- Game invites via Steam's `InviteUserToLobby`

The binary is bundled inside the `.vmz` and extracted to the user data directory on first launch. Platform-specific versions are included (`.exe` for Windows/Proton, native binary for Linux).

---

## Project Structure

```
mod/
  mod.txt                          # Mod loader manifest
  autoload/
    coop_manager.gd                # Main singleton: peers, patches, lifecycle, avatar cache
  network/
    player_state.gd                # Position + footstep sync (20Hz, interpolated)
    world_state.gd                 # Doors, switches, transitions, pickups, simulation
    steam_bridge.gd                # Steam helper IPC (localhost TCP, JSON)
    slot_serializer.gd             # SlotData <-> Dictionary for RPC transmission
  patches/
    controller_patch.gd            # Movement, input, audio, surface detection
    door_patch.gd                  # Door interaction sync
    switch_patch.gd                # Switch interaction sync
    transition_patch.gd            # Map transition sync
    pickup_patch.gd                # Pickup interaction sync
    loot_container_patch.gd        # Container sync (disabled)
  presentation/
    remote_player.gd               # Ghost capsule visual + spatial audio
    remote_player.tscn
  ui/
    coop_ui.gd                     # Multiplayer panel, lobby browser, friend invites
    coop_hud.gd                    # Player list, ping overlay, avatars
  bin/                             # Bundled binaries (included in .vmz)
    steam_helper_linux             # Go helper (Linux)
    steam_helper.exe               # Go helper (Windows / Proton)
    libsteam_api.so                # Steamworks SDK 1.64 (Linux)
    steam_api64.dll                # Steamworks SDK 1.64 (Windows)
    steam_appid.txt                # App ID (2141300)
  steam_helper/                    # Go source (not included in .vmz)
    main.go
    go.mod / go.sum
  build.sh                         # Packages .vmz archive
```

---

## Building from Source

### Prerequisites

- [Go 1.21+](https://go.dev/) for the Steam helper
- [Godot 4.6+](https://godotengine.org/) for editor testing
- Steamworks SDK 1.64 redistributable binaries (`libsteam_api.so`, `steam_api64.dll`)

### Build the Steam Helper

```bash
cd mod/steam_helper

# Linux
GOOS=linux GOARCH=amd64 go build -o bin/steam_helper_linux .

# Windows (cross-compile from Linux)
GOOS=windows GOARCH=amd64 go build -o bin/steam_helper.exe .
```

Place the Steamworks SDK 1.64 redistributable binaries in `steam_helper/bin/`:
- `libsteam_api.so` (from `redistributable_bin/linux64/`)
- `steam_api64.dll` (from `redistributable_bin/win64/`)

### Package the Mod

```bash
cd mod
./build.sh
# Output: mod/rtv-coop.vmz
```

The build script copies helper binaries and SDK libs into `mod/bin/`, then creates a ZIP archive with `mod.txt` at the root.

---

## Compatibility

### Mod Conflicts

This mod patches game scripts via `take_over_path()`. Any other mod patching the same scripts will conflict:

| Script | Conflict Risk |
|--------|---------------|
| `Controller.gd` | **High** -- most gameplay mods touch this |
| `Door.gd` | Low |
| `Switch.gd` | Low |
| `Transition.gd` | Low |
| `Pickup.gd` | Low |

### Game Updates

The mod checks script hashes at startup. If the game updates and scripts change, patches still apply but may cause issues. Check the console for `WARNING: hash mismatch` and look for a mod update.

---

## Known Limitations

- **Loot container sync disabled** -- conflicts with TraderDisplay type checks
- **No combat sync** -- weapons, hits, and damage are local only
- **No AI awareness** -- enemies only detect the host player
- **Ghost capsule model** -- remote players shown as translucent capsules (full model planned)
- **Steam P2P tunnel** -- NAT traversal via Steam Networking Sockets is available; players connect through Steam's relay network without port forwarding

---

## Roadmap

- [x] Phase 1 -- Position sync, ghost visuals, connection UI
- [x] Steam -- Lobby browser, friend invites, avatars, persona names
- [x] Phase 2 -- World state sync (doors, switches, time/weather)
- [x] Phase 2.5 -- Transitions, pickups, footstep audio
- [x] Mod Loader -- Metro Mod Loader `.vmz` packaging, Proton support
- [x] Steam P2P -- NAT traversal via Steam Networking Sockets
- [ ] Loot containers -- resolve TraderDisplay conflict
- [ ] Phase 3 -- AI multi-player awareness
- [ ] Phase 4 -- Combat sync (weapons, hits, damage)
- [ ] Third-person model -- Bandit mesh for remote players
- [ ] Voice chat

---

## Credits

- **Game**: [Road to Vostok](https://roadtovostok.com/) by Antti Vare
- **Mod Loader**: [Metro Mod Loader](https://modworkshop.net/mod/48937) by the RTV modding community
- **Steam Bindings**: [go-steamworks](https://github.com/badhex/go-steamworks) by badhex
- **Steamworks SDK**: [Valve Corporation](https://partner.steamgames.com/)
- **VostokMods**: [Ryhon0](https://github.com/Ryhon0/VostokMods)

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
