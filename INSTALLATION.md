# Installation Guide

## Prerequisites

- [Road to Vostok](https://store.steampowered.com/app/1963610/Road_to_Vostok/) installed via Steam
- Steam running

---

## Step 1: Install Metro Mod Loader

The mod requires the [Metro Mod Loader](https://modworkshop.net/mod/55623) to load `.vmz` mod archives.

### Windows

1. Download Metro Mod Loader from [modworkshop.net](https://modworkshop.net/mod/55623)
2. Copy `override.cfg` and `modloader.gd` into the **game install directory**:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
   > Your Steam library path may differ. Right-click the game in Steam > Manage > Browse Local Files.
3. Create a `mods` folder in the **game install directory** if it doesn't exist:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\
   ```

Your game directory should look like:
```
Road to Vostok/
  RTV.exe
  RTV.pck
  override.cfg          <- from Metro Mod Loader
  modloader.gd          <- from Metro Mod Loader
  mods/                 <- you create this
    rtv-coop.vmz        <- co-op mod goes here
```

### Linux (Proton)

Road to Vostok runs under Proton on Linux.

> **First time?** Launch the game once through Steam and close it. This creates the Proton prefix.

1. Download Metro Mod Loader from [modworkshop.net](https://modworkshop.net/mod/55623)
2. Copy `override.cfg` and `modloader.gd` into the **game install directory**:
   ```
   ~/.local/share/Steam/steamapps/common/Road to Vostok/
   ```
3. Create a `mods` folder in the **game install directory**:
   ```bash
   mkdir -p ~/.local/share/Steam/steamapps/common/Road\ to\ Vostok/mods
   ```

Your game directory should look like:
```
~/.local/share/Steam/steamapps/common/Road to Vostok/
  RTV.exe
  RTV.pck
  override.cfg          <- from Metro Mod Loader
  modloader.gd          <- from Metro Mod Loader
  mods/                 <- you create this
    rtv-coop.vmz        <- co-op mod goes here
```

---

## Step 2: Install the Co-op Mod

1. Download `rtv-coop.vmz` from the [Releases](https://github.com/plaught-armor/mod/releases) page
2. Place it in the `mods` folder in the **game install directory**:
   - **Windows:** `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\rtv-coop.vmz`
   - **Linux:** `~/.local/share/Steam/steamapps/common/Road to Vostok/mods/rtv-coop.vmz`
3. Launch the game through Steam
4. You should see **[Ins] Multiplayer** in the top-right corner

---

## Step 3: Verify

Once in-game and loaded into a map:

1. **Top-right corner** shows `[Ins] Multiplayer` -- Steam is connected
2. Press **INS** (Insert key) to open the multiplayer panel
3. You should see **Host**, **Refresh**, and **Invite** buttons
4. Your Steam profile picture should appear in the player list when hosting

If the HUD shows `Steam: offline` or `Steam: connecting...`:
- Make sure Steam is running before launching the game
- Check the logs (see Troubleshooting below)
- Try restarting the game

---

## Updating the Mod

To update the mod, simply replace `rtv-coop.vmz` in the `mods` folder with the new version and relaunch the game.

---

## Uninstalling

### Remove the mod only
Delete `rtv-coop.vmz` from the `mods` folder.

### Remove Metro Mod Loader entirely
Delete `override.cfg` and `modloader.gd` from the game install directory.

---

## Troubleshooting

### Where are the logs?

**Game log (Godot):**

| Platform | Log path |
|----------|----------|
| **Windows** | `%APPDATA%\Road to Vostok\logs\godot.log` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/compatdata/1963610/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/logs/godot.log` |

**Steam helper log:**

| Platform | Log path |
|----------|----------|
| **Windows** | Game install directory (next to `RTV.exe`): `steam_helper.log` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/common/Road to Vostok/steam_helper.log` |

**What's in each log:**
- **Godot log** (`godot.log`) -- mod loading, script patching, connection events, RPC activity. Lines prefixed with `[CoopManager]` and `[SteamBridge]`.
- **Helper log** (`steam_helper.log`) -- Steam API init, lobby creation, friend list, P2P tunnel, RunCallbacks status. Lines prefixed with `[steam_helper]`.

> **Reporting bugs:** When reporting an issue, include **both** log files. The Godot log shows what the game is doing, the helper log shows what Steam is doing. Without both, it's hard to diagnose.

### "Steam: offline"

- Ensure Steam is running before launching the game
- Check the helper log for errors (see above)
- On Linux, if this is your first time running the game, launch it once without the mod to let Proton create the prefix, then install the mod

### Proton prefix doesn't exist

The Proton prefix (`~/.local/share/Steam/steamapps/compatdata/1963610/`) is created the first time you launch the game through Steam. If it doesn't exist:
1. Launch Road to Vostok through Steam normally
2. Wait for it to reach the main menu
3. Close the game
4. The prefix folder should now exist

### Game won't start after installing the mod

- Verify `override.cfg` and `modloader.gd` are both in the game install directory (next to `RTV.exe`)
- Make sure `rtv-coop.vmz` is in the `mods` subfolder, not the root
- Try removing the mod (`rtv-coop.vmz`) to confirm the game starts without it

### Mouse stuck / can't look around

Press **INS** to close the multiplayer panel. The panel captures the mouse when open.
