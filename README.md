# Road to Vostok Co-op

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/). Play the hardcore survival FPS with friends.

## Features

- **Co-op multiplayer** with 20Hz position sync and interpolation
- **Steam integration** -- lobby browser, friend invites with avatars, P2P NAT traversal
- **Direct connect** -- host via IP for non-Steam or LAN play
- **World state sync** -- doors, switches, containers, time/weather synced between all players
- **AI multi-player awareness** -- enemies detect, target, and fight all players (host-authoritative, 10Hz replication)
- **Combat sync** -- weapon fire audio, muzzle flash, bullet impact decals, AI damage routing, grenade throws, explosion damage, mine detonation
- **Death sync** -- remote players removed on death, AI stops targeting dead players
- **Trader sync** -- host-authoritative trading with ACK flow (client items restored on reject)
- **World events** -- helicopters, BTRs, airdrops, crash sites, police patrols synced from host
- **Furniture sync** -- placement and pickup replicated between all players
- **Campfire sync** -- fire ignite/extinguish replicated between all players
- **Deterministic layouts** -- room layouts seeded from node path, consistent across all peers
- **Deterministic fishing** -- fish pools seeded for identical spawns, activate near any player
- **Sleep blocked in co-op** -- prevents time desync from bed usage
- **Per-world saves** -- each hosted world has its own save directory; player characters persist per-world
- **World picker** -- choose to create a new world or continue an existing one when hosting
- **Independent map transitions** -- players can explore different maps simultaneously
- **Headless AI** -- host runs AI for remote maps via SubViewport, enemies detect all players everywhere
- **Remote player audio** -- footsteps, jumps, landings, gunshots, and bullet impacts play spatially
- **Host-authoritative pickups** -- prevents item duplication
- **Non-destructive** -- installs as a `.vmz` mod archive, no game files modified
- **Ping overlay** -- HUD showing connected players, avatars, and round-trip times

---

## Installation

> See [INSTALLATION.md](INSTALLATION.md) for detailed step-by-step instructions including RTV Mod Loader setup and Linux/Proton paths.

### Quick Start

1. Install the [RTV Mod Loader](https://github.com/plaught-armor/RTV-Mod-Loader)
2. Download `rtv-coop.vmz` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
3. Place it in the `mods/` folder (see [INSTALLATION.md](INSTALLATION.md) for your platform's path)
4. Launch the game through Steam
5. The main menu should show **Singleplayer** and **Multiplayer** buttons

---

## Usage

### Controls

| Key | Action |
|-----|--------|
| **F12** | Toggle player/ping HUD |
| **Esc** | In-game settings menu with Multiplayer tab |

### Hosting (Steam)

1. From main menu, click **Multiplayer**
2. Click **Host (Steam)** -- a world picker appears
3. Choose **+ New World** or select an existing world
4. Share the lobby or invite friends

### Hosting (Direct IP)

1. From main menu, click **Multiplayer**
2. Click **Host (IP)** and select a world
3. Share your IP address with the other player

### Joining

1. From main menu, click **Multiplayer**
2. **Browse** to see available Steam lobbies, or **Direct Join** to connect via IP
3. Click a lobby to join

### Inviting Friends

1. Host a game first
2. Open the **Esc** menu > **Multiplayer** tab
3. Click **Invite** next to a friend's name

### In-Game Session Controls

Open the **Esc** menu > **Multiplayer** tab to see connected players, invite friends, copy your IP, or disconnect.

---

## Troubleshooting

### "Steam: offline"

- Make sure Steam is running before launching the game
- On first launch, restart the game (the helper binary extracts on first run)
- Check the [logs](#where-are-the-logs) for `[SteamBridge]` errors

### Where are the logs?

Both log files live in the same `logs/` directory. **Include both when reporting bugs.**

| Platform | Logs directory |
|----------|---------------|
| Windows | `%APPDATA%\Road to Vostok\logs\` |
| Linux (Proton) | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/` |

- `godot.log` -- game events, mod loading, connections
- `steam_helper.log` -- Steam API, lobbies, P2P tunnel

### Other Issues

- **Mouse stuck** -- Press **Esc** to close the settings menu
- **Can't see other player** -- Both players must be on the same map
- **Invite button doesn't show friends** -- You must host first. Only online friends are shown
- **Game broken after update** -- Road to Vostok updated and patches may be incompatible. Check for a mod update

---

## Known Limitations

- **Ghost capsule model** -- remote players shown as translucent capsules (full model planned)
- **No voice chat** -- use Steam/Discord voice as a workaround
- **Inventory is independent** -- each player manages their own loot; no shared inventory view
- **Knife swing animations not visible** -- melee audio and hit decals sync, but other players don't see the swing animation
- **Random events (helicopters, etc.)** -- visual events are not replayed for players who join mid-session (crash sites with loot are replayed)

---

## Roadmap

- [x] Position sync, ghost visuals, connection UI
- [x] Steam lobbies, friend invites, avatars, P2P NAT traversal
- [x] World state sync (doors, switches, time/weather)
- [x] Loot container sync
- [x] Transitions, pickups, footstep audio
- [x] RTV Mod Loader packaging, Proton support
- [x] AI multi-player awareness (detection, targeting, host-authoritative replication)
- [x] Combat sync (weapon fire, bullet impacts, AI damage routing)
- [x] Client equipment save across transitions
- [x] Grenade sync (throw physics, detonation, explosion/smoke effects)
- [x] Independent map transitions (headless SubViewport AI on host)
- [x] Explosion/mine damage sync (host-authoritative)
- [x] Death state sync and player cleanup
- [x] Campfire state sync
- [x] Per-world persistent saves with world picker
- [x] Trader sync (host-authoritative ACK flow)
- [x] World event sync (helicopters, BTR, airdrops, crash sites, police, cat)
- [x] Furniture placement/catalog sync
- [x] Deterministic room layouts and fish pools
- [x] Sleep blocked in co-op
- [x] Direct connect (IP-based, non-Steam)
- [x] Settings panel with multiplayer tab
- [ ] Third-person player model
- [x] Knife attack sync (audio + hit decals; swing animation not yet visible)
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
| `Loader.gd` | Medium |
| `Settings.gd` | Medium |
| `Bed.gd` | Low |
| `Character.gd` | Low |
| `Door.gd` | Low |
| `EventSystem.gd` | Low |
| `Explosion.gd` | Low |
| `Fire.gd` | Low |
| `FishPool.gd` | Low |
| `Furniture.gd` | Low |
| `GrenadeRig.gd` | Low |
| `KnifeRig.gd` | Low |
| `Layouts.gd` | Low |
| `LootContainer.gd` | Low |
| `LootSimulation.gd` | Low |
| `Mine.gd` | Low |
| `Pickup.gd` | Low |
| `Switch.gd` | Low |
| `Trader.gd` | Low |
| `Transition.gd` | Low |

---

## For Developers

### Building from Source

Requires [Go 1.21+](https://go.dev/) and [Godot 4.6+](https://godotengine.org/).

```bash
# Build Steam helper (both platforms)
cd steam_helper
GOOS=linux GOARCH=amd64 go build -o bin/steam_helper_linux .
GOOS=windows GOARCH=amd64 go build -o bin/steam_helper.exe .

# Package .vmz and auto-deploy to game mods folder
cd ..
go run build.go                   # dev build, auto-deploy
go run build.go rtv-coop release  # release build (app ID 1963610)
```

Steamworks SDK 1.64 redistributable binaries (`libsteam_api.so`, `steam_api64.dll`) must be in `steam_helper/bin/`.

### Architecture

- **Mod loading**: `.vmz` archive loaded via RTV Mod Loader's `load_resource_pack()`
- **Script patching**: `take_over_path()` with `super.Method()` to preserve original behavior
- **Networking**: ENet via `ENetMultiplayerPeer`, host-authoritative with request/validate/broadcast RPCs
- **Steam helper**: Go binary on a single OS-locked thread, communicating via localhost TCP JSON. Required by Steamworks SDK threading model and critical for Proton compatibility
- **P2P tunnel**: Steam Networking Sockets relay with local UDP bridge to ENet

---

## Credits

- **Game**: [Road to Vostok](https://roadtovostok.com/) by Antti Vare
- **Mod Loader**: [RTV Mod Loader](https://github.com/plaught-armor/RTV-Mod-Loader)
- **Steam Bindings**: [go-steamworks](https://github.com/badhex/go-steamworks) by badhex
- **VostokMods**: [Ryhon0](https://github.com/Ryhon0/VostokMods)

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
