# Road to Vostok Co-op

A co-op multiplayer mod for [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/). Play the hardcore survival FPS with friends.

Current version: **0.2.0**. Built against Godot 4.6 and the [RTV Mod Loader](https://github.com/plaught-armor/RTV-Mod-Loader). Distributed as a non-destructive `.vmz` archive.

---

## Features

### Networking
- **Steam P2P** — lobby browser, friend invites with avatars, NAT-traversed transport, no port forwarding required
- **Direct connect** — host via IP for non-Steam or LAN play
- **ENet transport** — built-in Godot multiplayer with reliable / unreliable channels per data class

### Players
- **20 Hz position + rotation sync** with client-side interpolation
- **Remote rigs** — full AI body model (Bandit / Guard / Military / Punisher) with character-picker, synced pose, weapon grip, equipment changes
- **Spatial audio** — footsteps, jumps, landings, gunshots, bullet impacts, instruments play from each remote rig
- **Death sync** — peers removed cleanly, AI drops dead targets
- **Vitals readout** — host receives each peer's health (~0.5 Hz) for HUD; vitals remain locally simulated

### World state (host-authoritative)
- **AI** — spawn, target selection, damage, loadout (10 Hz pose replication; AI detects every player)
- **Doors / switches / containers / pickups / fire / mines** — edge-triggered reliable RPCs
- **Time / weather** — broadcast on change
- **Loot** — host generates and validates; prevents duplication on edge cases
- **Vehicles** — Helicopter, BTR, CASA, Police share host-driven pose at 10 Hz
- **World events** — helicopters, BTRs, airdrops (CASA), crash sites, police patrols, missile launches
- **Furniture, campfires, radio / TV / instrument toggles** — placement / state replicated
- **Quests + cat-rescue** — trader tasks + side-quest state replicated; late-joiners see host progression
- **Trader sync** — host-authoritative trading with ACK flow (client items restored on reject)

### Determinism
- **Room layouts** — seeded from node path; consistent across peers
- **Fishing pools** — seeded for identical spawns; activate near any player

### Sessions
- **Per-world saves** — each hosted world has its own save directory; player characters persist per-world
- **World picker** — create new or continue existing on host start
- **Independent map transitions** — players can explore different maps simultaneously
- **Headless AI** — host runs AI for remote maps via SubViewport so enemies detect every player everywhere
- **Multi-peer sleep** — all peers at the same bed must be ready; HUD shows N / M ready count

### UI / observability
- **F11 coop panel** — host / browse / direct-join / invite / disconnect, in-game
- **F12 player + ping HUD**
- **Esc settings menu** unchanged from vanilla; multiplayer controls live on F11

---

## Installation

> See [INSTALLATION.md](INSTALLATION.md) for detailed step-by-step instructions including RTV Mod Loader setup and Linux / Proton paths.

### Releases

Each tagged release ships two artifacts on [Releases](https://github.com/plaught-armor/RTV-Coop/releases):

| File | Use |
|------|-----|
| `rtv-coop-X.Y.Z.vmz` | mod only — drop into existing `mods/` (you already have RTV Mod Loader) |
| `rtv-coop-setup-X.Y.Z.zip` | full bundle — `modloader.gd` + `override.cfg` + `mods/rtv-coop.vmz`. Drop into game folder for first-time install |

### Quick Start (first install)

1. Download `rtv-coop-setup-X.Y.Z.zip` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
2. Extract into game folder (see [INSTALLATION.md](INSTALLATION.md) for your platform's path)
3. Launch the game through Steam
4. Main menu shows **Singleplayer** and **Multiplayer** buttons

### Quick Start (mod update only)

1. Download `rtv-coop-X.Y.Z.vmz` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
2. Replace existing `mods/rtv-coop.vmz` in game folder
3. Re-launch

---

## Usage

### Keybinds

| Key | Action |
|-----|--------|
| **F11** | Toggle in-game coop panel (host / browse / join / invite / disconnect) |
| **F12** | Toggle player + ping HUD |
| **Esc** | Vanilla settings menu (unchanged) |

The coop panel swallows Esc and Tab while open so the vanilla settings and inventory cannot fire underneath.

### Hosting (Steam)

1. From the main menu click **Multiplayer**.
2. Click **Host (Steam)** — a world picker appears.
3. Choose **+ New World** or select an existing world.
4. Share the lobby or invite friends from the F11 panel once in-game.

### Hosting (Direct IP)

1. From the main menu click **Multiplayer**.
2. Click **Host (IP)** and select a world.
3. Share your IP address with the other player; they connect via **Direct Join**.

### Joining

1. From the main menu click **Multiplayer**.
2. **Browse** lists available Steam lobbies, or **Direct Join** connects via IP.
3. Click a lobby to join.

### Inviting Friends

#### Via Steam

1. Host a game using **Host (Steam)**.
2. Press **F11** in-game to open the coop panel.
3. Online Steam friends are listed on the right column — click **Invite** next to a friend.
4. They receive a Steam notification and join automatically.

#### Via IP

1. Host a game using **Host (IP)** (or **Host (Steam)** — IP works either way).
2. Share your IP, shown in the F11 panel.
3. The other player clicks **Direct Join** from the Multiplayer menu and enters your IP.

> **Note:** Steam invites require both players to own the game on Steam. Direct IP works without Steam but requires port forwarding or LAN access.

---

## Sync Rates Reference

| Data | Authority | Channel | Rate |
|------|-----------|---------|------|
| Player position / rotation | client | unreliable | 20 Hz |
| Player movement flags / death | client | reliable | edge |
| Player vitals (HUD readout) | client | unreliable | ~0.5 Hz |
| AI position / state | host | unreliable | 10 Hz |
| Vehicle pose | host | unreliable | 10 Hz |
| Door / switch / container / pickup / fire / mine | host | reliable | edge |
| Damage / loot mutation | host | reliable | event |
| Time / weather | host | reliable | on change |
| Character save on transition | client → host | reliable (file bytes) | event |

Physics tick is 120 Hz; per-rate "every N ticks" constants live in `network/*.gd`.

---

## Troubleshooting

### "Steam: offline"

- Make sure Steam is running before launching the game.
- On first launch restart the game (the helper binary extracts on first run).
- Check the [logs](#where-are-the-logs) for `[SteamBridge]` errors.

### Where are the logs?

Both log files live in the same `logs/` directory. **Include both when reporting bugs.**

| Platform | Logs directory |
|----------|----------------|
| Windows | `%APPDATA%\Road to Vostok\logs\` |
| Linux (Proton) | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/` |

- `godot.log` — game events, mod loading, connections, RPC traffic
- `steam_helper.log` — Steam API, lobbies, P2P tunnel

### Other Issues

- **Mouse stuck** — press **F11** or **Esc** to close whatever is open.
- **Can't see other player** — both players must be on the same map.
- **Invite list empty** — you must host first; only online friends are shown.
- **Game broken after game update** — Road to Vostok released a new build and the hooks may need refreshing. Check for a mod update; if hooks were renamed, run `python3 .claude/tools/audit_hook_targets.py` from a working tree to confirm.

---

## Known Limitations

- **No voice chat** — use Steam / Discord voice as a workaround.
- **Inventory is independent** — each player manages their own loot; no shared inventory view.
- **Reload animation on remote rig** — AI skeletons have no reload clips; other players don't see your reload motion (firing / walking / crouching do animate).
- **Knife swing animations not visible** — melee audio and hit decals sync, but other players don't see the swing.
- **Mid-session join** — random visual events (helicopters, etc.) are not replayed for late joiners; crash sites with loot are replayed.
- **Cross-player vitals** — health is broadcast for HUD display only; damage / vitals simulation remains per-peer local.

---

## Roadmap

- [x] Player sync and remote rig visuals
- [x] Steam lobbies, friend invites, P2P
- [x] Direct connect (IP)
- [x] World state (doors, switches, containers, time / weather)
- [x] AI awareness and replication
- [x] Combat (weapons, grenades, explosions, mines, knives)
- [x] Death sync
- [x] Traders + quest sync
- [x] World events (helicopters, BTR, CASA airdrop, crash sites, police, missiles)
- [x] Furniture placement
- [x] Campfires
- [x] Radio / TV / instrument sync
- [x] Cat rescue quest sync
- [x] Multi-peer bed sleep ready-gate
- [x] Fishing pools
- [x] Room layout determinism
- [x] Per-world saves
- [x] Map transitions
- [x] Proton / Linux support
- [ ] Reload animations on remote rig
- [ ] Knife swing animations on remote rig
- [ ] Voice chat
- [ ] FPS arm animation forwarding to remote viewers
- [ ] Trader shelf supply sync between peers
- [ ] Mod compatibility improvements

---

## Mod Compatibility

### Script-swap conflicts (`take_over_path`)

Two vanilla scripts are still swapped via `take_over_path()` — they sit on the vostok-mod-loader skip-list and cannot use the hook API. Any other mod that swaps the same path conflicts at the script level.

| Script | Risk |
|--------|------|
| `Mine.gd` | Low |
| `Explosion.gd` | Low |

### Hook-API conflicts (RTVModLib)

21 vanilla scripts are extended via the `RTVModLib` hook API (`pre`, `post`, `replace` semantics, with `skip_super` for replace). Other mods registering `pre` / `post` hooks on the same vanilla methods can interleave non-destructively — order is registration order, and CoopManager registers in a deferred call from `_ready`. `replace` hooks from multiple mods on the same method conflict.

| Vanilla script | Hook surface |
|----------------|--------------|
| `Controller.gd` | footstep + interaction dispatch |
| `AI.gd` | spawn / death / loadout sync |
| `AISpawner.gd` | pool creation + sync-id assign |
| `Interactor.gd` | item / transition / interactable dispatch |
| `Interface.gd` | trade UI + inventory hooks |
| `Loader.gd` | character / shelter / trader save sync |
| `BTR.gd`, `CASA.gd`, `Helicopter.gd`, `Police.gd` | vehicle authority |
| `Character.gd`, `EventSystem.gd` | event broadcast + character lifecycle |
| `FishPool.gd`, `Furniture.gd`, `GrenadeRig.gd`, `KnifeRig.gd` | placement + rig sync |
| `LootSimulation.gd` | host-authoritative loot mutation |
| `MissileSpawner.gd`, `RocketGrad.gd`, `RocketHelicopter.gd` | projectile sync |
| `Trader.gd` | trader visibility + supply |

In addition, `Instrument.gd` and `Layouts.gd` are observed via SceneTree node-watcher patterns (`mod/network/instrument_hook.gd`, `layouts_hook.gd`) without registering RTVModLib hooks. Other mods that hook these scripts will not collide at the registration layer but may diverge in observed state.

### Other conflict surfaces

| Surface | Risk |
|---------|------|
| **Autoload name** — `CoopManager` is registered with the early-load `!` prefix (`mod.txt`). Another mod claiming the same name fails to load. | High |
| **ENet host port** — defaults to **9050** (`coop_manager.gd`). Conflicting mod also binding 9050 fails to host over IP. | Medium |
| **Steam helper** — Go binary speaks JSON over a localhost TCP socket. Another mod or process binding the same loopback port reports `Steam: offline`. | Medium |
| **`GameData.tres`** — vanilla shared `Resource`. Mods mutating the same fields (health, position) race host-authoritative writes during co-op sessions. | Medium |
| **Scene injections** — coop UI inserts nodes under main menu, settings, and HUD. Mods replacing those scenes wholesale lose the multiplayer buttons. | Medium |
| **Save layout** — coop writes per-world subdirs under `user://coop/`. Mods writing to the same path may corrupt persistence. | Low |

---

## For Developers

### Building from Source

Requires [Go 1.21+](https://go.dev/) and [Godot 4.6+](https://godotengine.org/).

```bash
# Build Steam helper for both platforms
cd steam_helper
GOOS=linux GOARCH=amd64 go build -o bin/steam_helper_linux .
GOOS=windows GOARCH=amd64 go build -o bin/steam_helper.exe .

# Package .vmz and auto-deploy to game mods folder
cd ..
go run build.go                          # dev build (Steam appID 480 = Spacewar), auto-deploy
go run build.go rtv-coop release         # release build (appID 1963610), auto-deploy
go run build.go rtv-coop release no-deploy   # release build, skip deploy
```

Steamworks SDK 1.64 redistributable binaries (`libsteam_api.so`, `libsteam_api64.so`, `steam_api64.dll`) must be in `steam_helper/bin/`.

### Hook target audit

After every Road to Vostok game update, run the audit script from the project root:

```bash
python3 .claude/tools/audit_hook_targets.py
```

It verifies every vanilla method called from `mod/hooks/` still exists in the decompiled `Scripts/`. A renamed vanilla method otherwise crashes silently at the first invocation.

### Architecture

- **Mod loading** — `.vmz` archive loaded via vostok-mod-loader's `load_resource_pack()`.
- **Script patching** — `RTVModLib` hook API (`pre` / `post` / `replace` + `skip_super`) for 21 scripts; `take_over_path()` fallback for `Mine.gd` and `Explosion.gd` only (vostok skip-list).
- **Networking** — ENet via `ENetMultiplayerPeer`, host-authoritative with request / validate / broadcast RPCs. RPC-bearing scripts must be `preload`ed (not `load`ed) so the same script ID is registered on every peer.
- **Steam helper** — Go binary on a single OS-locked thread, communicating via localhost TCP JSON. Required by the Steamworks SDK threading model and critical for Proton compatibility.
- **P2P tunnel** — Steam Networking Sockets relay with a local UDP bridge to ENet.
- **Autoload** — `CoopManager` declared early via `!` prefix in `mod.txt`. Path normalized to `/root/CoopManager` on `_ready` via deferred reparent so the parser-visible global resolves under the same path during gameplay.

---

## Credits

- **Game** — [Road to Vostok](https://roadtovostok.com/) by Antti Vare
- **Mod Loader** — [RTV Mod Loader](https://github.com/plaught-armor/RTV-Mod-Loader)
- **Steam Bindings** — [go-steamworks](https://github.com/badhex/go-steamworks) by badhex
- **VostokMods reference** — [Ryhon0](https://github.com/Ryhon0/VostokMods)

## License

This mod is provided as-is for personal use. Road to Vostok is the property of its developer.
