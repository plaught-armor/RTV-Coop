# Co-op Mod Installation

## Prerequisites

- [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/) installed via Steam
- [RTV Mod Loader](https://github.com/plaught-armor/RTV-Mod-Loader) installed (see its README for setup)
- Steam running

## Install

1. Download `rtv-coop.vmz` from [Releases](https://github.com/plaught-armor/RTV-Coop/releases)
2. Place it in the `mods` folder in your game install directory:
   - **Windows:** `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\`
   - **Linux:** `~/.local/share/Steam/steamapps/common/Road to Vostok/mods/`
3. Launch the game through Steam
4. You should see **[Ins] Multiplayer** in the top-right corner

## Verify

Once in-game and loaded into a map:

1. **Top-right corner** shows `[Ins] Multiplayer`
2. Press **INS** (Insert key) to open the multiplayer panel
3. You should see **Host**, **Refresh**, and **Invite** buttons

If the HUD shows `Steam: offline` or `Steam: connecting...`:
- Make sure Steam is running before launching the game
- Check the logs (see below)

## Updating

Replace `rtv-coop.vmz` in the `mods` folder with the new version and relaunch.

## Uninstalling

Delete `rtv-coop.vmz` from the `mods` folder.

## Logs

Both log files live in the same `logs/` directory:

| Platform | Logs directory |
|----------|---------------|
| **Windows** | `%APPDATA%\Road to Vostok\logs\` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/` |

- `godot.log` -- game events, mod loading, connections
- `steam_helper.log` -- Steam API, lobbies, P2P tunnel

Lines prefixed `[CoopManager]` and `[SteamBridge]` are from the mod. Include both logs when reporting issues.
