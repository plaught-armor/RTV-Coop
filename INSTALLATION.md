# Installation Guide

## Prerequisites

- [Road to Vostok](https://store.steampowered.com/app/2141300/Road_to_Vostok/) installed via Steam
- Steam running

---

## Step 1: Install Metro Mod Loader

The mod requires the [Metro Mod Loader](https://modworkshop.net/mod/48937) to load `.vmz` mod archives.

### Windows

1. Download Metro Mod Loader from [modworkshop.net](https://modworkshop.net/mod/48937)
2. Open your game's `AppData` folder:
   - Press `Win+R`, type `%APPDATA%\Road to Vostok Demo`, press Enter
   - Or navigate manually to `C:\Users\<YourName>\AppData\Roaming\Road to Vostok Demo\`
3. Copy the Metro Mod Loader files into this folder:
   - `override.cfg`
   - `modloader.gd`
4. Create a `mods` folder inside the same directory if it doesn't exist:
   ```
   C:\Users\<YourName>\AppData\Roaming\Road to Vostok Demo\mods\
   ```

Your folder should look like:
```
Road to Vostok Demo/
  override.cfg          <- from Metro Mod Loader
  modloader.gd          <- from Metro Mod Loader
  mods/                 <- you create this
```

### Linux (Proton)

Road to Vostok runs under Proton on Linux. Proton creates a virtual Windows filesystem where `AppData/Roaming` is mapped to a folder inside the Proton prefix. The Metro Mod Loader installs the same way — you just need to find the right path.

1. Download Metro Mod Loader from [modworkshop.net](https://modworkshop.net/mod/48937)
2. Find the game's app ID folder in your Proton compatibility data:
   ```
   ~/.local/share/Steam/steamapps/compatdata/
   ```
   Road to Vostok Demo's app ID is **2141300**, so the folder is:
   ```
   ~/.local/share/Steam/steamapps/compatdata/2141300/
   ```
3. Navigate to the `AppData/Roaming` equivalent:
   ```
   ~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok Demo/
   ```
   > **Note:** This folder is created by Proton the first time you launch the game. If it doesn't exist, launch the game once through Steam and close it.

4. Copy the Metro Mod Loader files into this folder:
   - `override.cfg`
   - `modloader.gd`
5. Create a `mods` folder inside the same directory:
   ```bash
   mkdir -p ~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road\ to\ Vostok\ Demo/mods
   ```

Your folder should look like:
```
Road to Vostok Demo/
  override.cfg
  modloader.gd
  mods/
  logs/                 <- created by the game
  Preferences.tres      <- created by the game
  ...
```

---

## Step 2: Install VMP (Vostok Multiplayer)

### Windows

1. Download `rtv-coop.vmz` from the [Releases](https://github.com/plaught-armor/mod/releases) page
2. Place it in the `mods` folder you created in Step 1:
   ```
   %APPDATA%\Road to Vostok Demo\mods\rtv-coop.vmz
   ```
3. Launch the game through Steam
4. You should see **INS Multiplayer** in the top-right corner of the screen

### Linux (Proton)

1. Download `rtv-coop.vmz` from Releases
2. Place it in the `mods` folder you created in Step 1:
   ```
   ~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok Demo/mods/rtv-coop.vmz
   ```
3. Launch the game through Steam
4. You should see **INS Multiplayer** in the top-right corner of the screen

---

## Step 3: Verify

Once in-game and loaded into a map:

1. **Top-right corner** shows `INS Multiplayer` -- Steam is connected
2. Press **INS** (Insert key) to open the multiplayer panel
3. You should see **Host**, **Refresh**, and **Invite** buttons
4. Your Steam profile picture should appear in the player list when hosting

If the HUD shows `Steam: offline` or `Steam: connecting...`:
- Make sure Steam is running before launching the game
- Check the logs (see Troubleshooting below)
- Try restarting the game

---

## Updating the Mod

To update VMP, simply replace `rtv-coop.vmz` in the `mods` folder with the new version and relaunch the game.

---

## Uninstalling

### Remove VMP only
Delete `rtv-coop.vmz` from the `mods` folder.

### Remove Metro Mod Loader entirely
Delete `override.cfg` and `modloader.gd` from the game's `AppData/Roaming` folder.

---

## Troubleshooting

### Where are the logs?

| Platform | Log path |
|----------|----------|
| **Windows** | `%APPDATA%\Road to Vostok Demo\logs\godot.log` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/compatdata/2141300/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok Demo/logs/godot.log` |

The Steam helper also writes its own log:

| Platform | Log path |
|----------|----------|
| **Windows** | The game's install directory (next to `RTV.exe`): `steam_helper.log` |
| **Linux (Proton)** | `~/.local/share/Steam/steamapps/common/Road to Vostok Demo/steam_helper.log` |

**What's in each log:**
- **Godot log** (`godot.log`) -- mod loading, script patching, connection events, RPC activity. Lines prefixed with `[CoopManager]` and `[SteamBridge]`.
- **Helper log** (`steam_helper.log`) -- Steam API init, lobby creation, friend list, P2P tunnel, RunCallbacks status. Lines prefixed with `[steam_helper]`.

> **Reporting bugs:** When reporting an issue, include **both** log files. The Godot log shows what the game is doing, the helper log shows what Steam is doing. Without both, it's hard to diagnose.

### "Steam: offline"

- Ensure Steam is running before launching the game
- Check the helper log for errors (see above)
- On Linux, if this is your first time running the game, launch it once without the mod to let Proton create the prefix, then install the mod

### Proton prefix doesn't exist

The Proton prefix (`~/.local/share/Steam/steamapps/compatdata/2141300/`) is created the first time you launch the game through Steam. If it doesn't exist:
1. Launch Road to Vostok Demo through Steam normally
2. Wait for it to reach the main menu
3. Close the game
4. The prefix folder should now exist

### Game won't start after installing the mod

- Verify `override.cfg` and `modloader.gd` are in the correct folder (AppData/Roaming, NOT the game install directory)
- Make sure `rtv-coop.vmz` is in the `mods` subfolder, not the root
- Try removing the mod (`rtv-coop.vmz`) to confirm the game starts without it

### Mouse stuck / can't look around

Press **INS** to close the multiplayer panel. The panel captures the mouse when open.


