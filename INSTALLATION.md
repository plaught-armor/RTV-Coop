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
4. The main menu shows **Singleplayer** and **Multiplayer** buttons

## Verify

1. From the main menu, click **Multiplayer** — submenu shows **Host (Steam)**, **Host (IP)**, **Browse**, **Direct Join**
2. Click **Host (Steam)** and pick (or create) a world — in-game HUD shows a connected peer count
3. In-game, press **Esc** to open the settings menu, then the **Multiplayer** tab — lists connected players, friends to invite, and the session IP
4. Press **F12** in-game to toggle the HUD overlay (player list + ping)

If the Multiplayer submenu shows `Steam: offline` or the Invite Friends list is empty:
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
