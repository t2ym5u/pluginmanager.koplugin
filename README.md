# pluginmanager.koplugin

A plugin manager for [KOReader](https://github.com/koreader/koreader) that lets you install, update, and remove game plugins from the [koreader-plugins](https://github.com/t2ym5u/koreader-plugins) repository directly on your device — no computer required.

## Features

- **Browse available plugins** — see every game plugin in the repository with its version
- **Install** — download and install any plugin with a single tap
- **Update** — detect newer versions and update with a single tap
- **Remove** — uninstall any plugin and delete its files
- **Offline view** — shows locally installed plugins even without network access

## Installation

Install this plugin once, manually. All subsequent plugins can then be managed from within KOReader.

1. Download `pluginmanager.koplugin.zip` from the [latest release](../../releases/latest).
2. Extract into the `plugins/` folder of your KOReader data directory:
   - **Kobo**: `koreader/plugins/`
   - **Kindle**: `/mnt/us/extensions/`
   - **PocketBook**: `applications/koreader/plugins/`
3. Restart KOReader.

## Usage

Open **Tools → Plugin Manager**.

| Action | How |
|--------|-----|
| Load the plugin catalogue | Tap **Fetch plugin list** |
| Install a new plugin | Tap a plugin in the *Available* section → **Install** |
| Update an installed plugin | Tap a plugin showing `v1.0 → v1.1` → **Update to v1.1** |
| Remove an installed plugin | Tap any installed plugin → **Remove** → confirm |
| Refresh after changes | Tap **Refresh list** |

After installing or removing a plugin, **restart KOReader** for the change to take effect.

### Sections

| Section | Contents |
|---------|----------|
| *Installed* | Plugins found both locally and in the repository. Shows a `→ vX.Y` arrow when an update is available. |
| *Installed (not in repo)* | Plugins installed locally that are not listed in the repository (e.g. from a third-party source). Only **Remove** is offered. |
| *Available* | Plugins in the repository that are not yet installed. |

## How it works

The plugin manager downloads a `manifest.json` file from the repository root. This file lists every available plugin along with its version and the individual source files it contains. Files are then fetched one by one from `raw.githubusercontent.com` and written directly to the KOReader `plugins/` directory.

Two shared libraries exist for plugins that vendor common code instead of duplicating it: `game-common` (ScreenBase-based games) and `sudoku-common` (BaseScreen-based sudoku variants — a different, incompatible API). A plugin's `common_lib` field in `manifest.json` names which one it needs. The named library is downloaded automatically the first time any plugin that depends on it is installed, and copied into that plugin's `common/` folder (a real copy, never a symlink, so it survives on any device); it's refreshed on every install/update to guarantee it's never stale.

Files are fetched with a short pacing delay between requests, and a 429 (rate limit) from `raw.githubusercontent.com` is retried with backoff rather than failing the whole update — useful during a bulk Update/Reinstall run that touches every installed plugin.

## For developers: releasing an update

1. Bump `version` in the plugin's `_meta.lua`.
2. Update the matching `version` field in `manifest.json` at the repository root.
3. If new source files were added to the plugin, add them to the `files` array in `manifest.json`.
4. Commit and push to `master`. The plugin manager always fetches from the `master` branch.

## Requirements

- KOReader with network access (Wi-Fi or mobile data)
- `ssl.https` and `ltn12` (bundled with KOReader on all supported devices)
- `rapidjson` for JSON parsing (bundled with KOReader)

## License

GPL-3.0
