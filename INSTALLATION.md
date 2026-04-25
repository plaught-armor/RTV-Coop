# Co-op Mod Installation

Two install paths — pick one:

- **First-time install** (no RTV Mod Loader yet): use `rtv-coop-setup-X.Y.Z.zip`
- **Mod update only** (RTV Mod Loader already installed): use `rtv-coop-X.Y.Z.vmz`

## Prerequisites

- [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/) installed via Steam
- Steam running

## First-time install (`rtv-coop-setup-X.Y.Z.zip`)

The setup bundle ships RTV Mod Loader + the co-op mod together — no separate ML install needed.

1. Download `rtv-coop-setup-X.Y.Z.zip` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
2. Extract directly into your game install directory (overwriting any existing `modloader.gd` / `override.cfg`):
   - **Windows:** `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\`
   - **Linux:** `~/.local/share/Steam/steamapps/common/Road to Vostok/`
3. Launch the game through Steam
4. The main menu shows **Singleplayer** and **Multiplayer** buttons

The bundle places:

```
Road to Vostok/
├─ modloader.gd
├─ override.cfg
└─ mods/
   └─ rtv-coop.vmz
```

## Mod update only (`rtv-coop-X.Y.Z.vmz`)

1. Download `rtv-coop-X.Y.Z.vmz` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
2. Replace `rtv-coop.vmz` in the `mods` folder of your game install directory:
   - **Windows:** `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\`
   - **Linux:** `~/.local/share/Steam/steamapps/common/Road to Vostok/mods/`
3. Re-launch the game through Steam

## Verify

1. From the main menu, click **Multiplayer** — submenu shows **Host (Steam)**, **Host (IP)**, **Browse**, **Direct Join**
2. Click **Host (Steam)** and pick (or create) a world — in-game HUD shows a connected peer count
3. In-game, press **Esc** to open the settings menu, then the **Multiplayer** tab — lists connected players, friends to invite, and the session IP
4. Press **F12** in-game to toggle the HUD overlay (player list + ping)

If the Multiplayer submenu shows `Steam: offline` or the Invite Friends list is empty:
- Make sure Steam is running before launching the game
- Check the logs (see below)

## Updating

Use `rtv-coop-X.Y.Z.vmz` (see "Mod update only" above) — replace existing `mods/rtv-coop.vmz` and relaunch.

## Uninstalling

Delete `rtv-coop.vmz` from the `mods` folder. To remove RTV Mod Loader entirely, also delete `modloader.gd` and `override.cfg` from the game folder.

## Logs

Both log files live in the same `logs/` directory:

| Platform | Logs directory |
|----------|---------------|
| **Windows** | `%APPDATA%\Road to Vostok\logs\` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/` |

- `godot.log` -- game events, mod loading, connections
- `steam_helper.log` -- Steam API, lobbies, P2P tunnel

Lines prefixed `[CoopManager]` and `[SteamBridge]` are from the mod. Include both logs when reporting issues.
