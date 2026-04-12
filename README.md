# Road to Vostok Co-op

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/). Play the hardcore survival FPS with up to 4 friends.

## Features

- **2-4 player co-op** with 20Hz position sync and interpolation
- **Steam integration** -- lobby browser, friend invites with avatars, P2P NAT traversal
- **World state sync** -- doors, switches, containers, time/weather synced between all players
- **AI multi-player awareness** -- enemies detect, target, and fight all players (host-authoritative, 10Hz replication)
- **Combat sync** -- weapon fire audio, muzzle flash, bullet impact decals, AI damage routing, grenade throws
- **Synchronized map transitions** -- all players transition and save together
- **Remote player audio** -- footsteps, jumps, landings, gunshots, and bullet impacts play spatially
- **Host-authoritative pickups** -- prevents item duplication
- **Non-destructive** -- installs as a `.vmz` mod archive, no game files modified
- **Ping overlay** -- HUD showing connected players, avatars, and round-trip times

---

## Installation

> See [INSTALLATION.md](INSTALLATION.md) for detailed step-by-step instructions including Metro Mod Loader setup and Linux/Proton paths.

### Quick Start

1. Install the [Metro Mod Loader](https://modworkshop.net/mod/55623)
2. Download `rtv-coop.vmz` from [Releases](https://github.com/plaught-armor/mod/releases)
3. Place it in the `mods/` folder (see [INSTALLATION.md](INSTALLATION.md) for your platform's path)
4. Launch the game through Steam
5. You should see **[Ins] Multiplayer** in the top-right corner

---

## Usage

### Controls

| Key | Action |
|-----|--------|
| **INS** (Insert) | Toggle multiplayer panel |
| **F10** | Quick host |
| **F12** | Toggle player/ping HUD |

### Hosting

1. Load into a map
2. Press **INS** to open the multiplayer panel
3. Click **Host** (or press **F10**)

### Joining

1. Load into any map
2. Press **INS** > **Refresh** to see available lobbies
3. Click a lobby to join

### Inviting Friends

1. Host a game first
2. Press **INS** > **Invite** to see your online Steam friends
3. Click **Invite** next to a friend's name

---

## Troubleshooting

### "Steam: offline"

- Make sure Steam is running before launching the game
- On first launch, restart the game (the helper binary extracts on first run)
- Check the [logs](#where-are-the-logs) for `[SteamBridge]` errors

### Where are the logs?

There are two log files. **Both are needed when reporting bugs.**

**Godot log** (game events, mod loading, connections):

| Platform | Path |
|----------|------|
| Windows | `%APPDATA%\Road to Vostok Demo\logs\godot.log` |
| Linux (Proton) | `~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok Demo/logs/godot.log` |

**Steam helper log** (Steam API, lobbies, P2P tunnel):

| Platform | Path |
|----------|------|
| Windows | Game install directory: `steam_helper.log` (next to `RTV.exe`) |
| Linux (Proton) | `~/.local/share/Steam/steamapps/common/Road to Vostok Demo/steam_helper.log` |

### Other Issues

- **Mouse stuck** -- Press **INS** to close the multiplayer panel
- **Can't see other player** -- Both players must be on the same map
- **Invite button doesn't show friends** -- You must host first. Only online friends are shown
- **Game broken after update** -- Road to Vostok updated and patches may be incompatible. Check for a mod update

---

## Known Limitations

- **Ghost capsule model** -- remote players shown as translucent capsules (full model planned)
- **Grenade damage is local** -- thrown grenades are synced visually but explosion damage is not host-authoritative yet
- **No voice chat** -- use Steam/Discord voice as a workaround
- **Inventory is independent** -- each player manages their own loot; no shared inventory view

---

## Roadmap

- [x] Position sync, ghost visuals, connection UI
- [x] Steam lobbies, friend invites, avatars, P2P NAT traversal
- [x] World state sync (doors, switches, time/weather)
- [x] Loot container sync
- [x] Transitions, pickups, footstep audio
- [x] Metro Mod Loader packaging, Proton support
- [x] AI multi-player awareness (detection, targeting, host-authoritative replication)
- [x] Combat sync (weapon fire, bullet impacts, AI damage routing)
- [x] Client equipment save across transitions
- [x] Grenade sync (throw physics, detonation, explosion/smoke effects)
- [ ] Third-person player model
- [ ] Voice chat

---

## Mod Conflicts

This mod patches game scripts via `take_over_path()`. Other mods patching the same scripts will conflict:

| Script | Risk |
|--------|------|
| `Controller.gd` | **High** |
| `AI.gd` | **High** |
| `AISpawner.gd` | Medium |
| `Interface.gd` | Medium |
| `Door.gd` | Low |
| `Switch.gd` | Low |
| `Transition.gd` | Low |
| `Pickup.gd` | Low |
| `LootContainer.gd` | Low |
| `LootSimulation.gd` | Low |
| `GrenadeRig.gd` | Low |

---

## For Developers

### Building from Source

Requires [Go 1.21+](https://go.dev/) and [Godot 4.6+](https://godotengine.org/).

```bash
# Build Steam helper
cd mod/steam_helper
GOOS=linux GOARCH=amd64 go build -o bin/steam_helper_linux .
GOOS=windows GOARCH=amd64 go build -o bin/steam_helper.exe .

# Package .vmz
cd mod
./build.sh
```

Steamworks SDK 1.64 redistributable binaries (`libsteam_api.so`, `steam_api64.dll`) must be in `steam_helper/bin/`.

### Architecture

- **Mod loading**: `.vmz` archive loaded via Metro Mod Loader's `load_resource_pack()`
- **Script patching**: `take_over_path()` with `super.Method()` to preserve original behavior
- **Networking**: ENet via `ENetMultiplayerPeer`, host-authoritative with request/validate/broadcast RPCs
- **Steam helper**: Go binary on a single OS-locked thread, communicating via localhost TCP JSON. Required by Steamworks SDK threading model and critical for Proton compatibility
- **P2P tunnel**: Steam Networking Sockets relay with local UDP bridge to ENet

---

## Credits

- **Game**: [Road to Vostok](https://roadtovostok.com/) by Antti Vare
- **Mod Loader**: [Metro Mod Loader](https://modworkshop.net/mod/55623)
- **Steam Bindings**: [go-steamworks](https://github.com/badhex/go-steamworks) by badhex
- **VostokMods**: [Ryhon0](https://github.com/Ryhon0/VostokMods)

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
