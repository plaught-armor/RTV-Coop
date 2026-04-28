# Co-op Mod Installation

The co-op mod requires the **vostok-mod-loader** (community ML for RTV).
Install loader first, then drop the co-op `.vmz` in `mods/`.

## Prerequisites

- [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/) installed via Steam
- Steam running
- [vostok-mod-loader](https://github.com/ametrocavich/vostok-mod-loader) installed in your game folder

## Step 1 — install vostok-mod-loader

Follow the [loader installer instructions](https://github.com/ametrocavich/vostok-mod-loader#installation):

1. Download `modloader.gd` + `override.cfg` from the loader's [Releases](https://github.com/ametrocavich/vostok-mod-loader/releases).
2. Drop both into your game install dir:
   - **Windows:** `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\`
   - **Linux:** `~/.local/share/Steam/steamapps/common/Road to Vostok/`
3. Create a `mods/` folder in the same dir if it doesn't exist.
4. Launch once to confirm — the loader's launcher window appears before the main menu.

## Step 2 — install co-op mod

1. Download `rtv-coop-X.Y.Z.vmz` from [Co-op Releases](https://github.com/plaught-armor/RTV-Coop/releases).
2. Drop it into the `mods/` folder you created above.
3. Launch the game through Steam.
4. In the loader window, ensure **Road to Vostok Co-op** is checked, then click **Launch Game**.
5. Main menu shows **Singleplayer** and **Multiplayer** buttons.

## Verify

1. From the main menu, click **Multiplayer** — submenu shows **Host (Steam)**, **Host (IP)**, **Browse**, **Direct Join**.
2. Click **Host (Steam)** and pick (or create) a world — in-game HUD shows a connected peer count.
3. In-game, press **Esc** to open the settings menu, then the **Multiplayer** tab — lists connected players, friends to invite, and the session IP.
4. Press **F12** in-game to toggle the HUD overlay (player list + ping).

If the Multiplayer submenu shows `Steam: offline` or the Invite Friends list is empty:
- Make sure Steam is running before launching the game.
- Check the logs (see below).

## Updating

Replace `rtv-coop.vmz` in `mods/` with the new release; relaunch.
For loader updates, replace `modloader.gd` in the game dir from the loader's Releases page.

## Uninstalling

- **Co-op only:** delete `rtv-coop.vmz` from `mods/`.
- **Loader + co-op:** also delete `modloader.gd` and `override.cfg` from the game dir.

## Logs

Both log files live in the same `logs/` directory:

| Platform | Logs directory |
|----------|---------------|
| **Windows** | `%APPDATA%\Road to Vostok\logs\` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/` |

- `godot.log` — game events, mod loading, connections.
- `steam_helper.log` — Steam API, lobbies, P2P tunnel.

Lines prefixed `[CoopManager]` and `[SteamBridge]` are from the mod. Include both logs when reporting issues.

## Migration from RTV-Mod-Loader (legacy)

The previous `rtv-coop-setup-X.Y.Z.zip` bundle shipped a fork of Metro Mod Loader (`RTV-Mod-Loader`). That fork is **deprecated** as of 2026-04-26 — `vostok-mod-loader` solves the same problems with a hook API (no whole-script `take_over_path`).

To migrate:

1. Delete the old `modloader.gd` + `override.cfg` from your game dir.
2. Install vostok-mod-loader (Step 1 above).
3. Replace `rtv-coop.vmz` with the latest release.
