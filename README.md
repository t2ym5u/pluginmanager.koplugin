# pluginmanager.koplugin

A plugin manager for [KOReader](https://github.com/koreader/koreader) that lets you install, update, and remove game plugins from the [koreader-plugins](https://github.com/t2ym5u/koreader-plugins) repository directly on your device — no computer required.

## Features

- **Browse available plugins** — see every game plugin in the repository with its version
- **Install** — download and install any plugin with a single tap
- **Update** — detect newer versions and update with a single tap
- **Remove** — uninstall any plugin and delete its files
- **Offline view** — shows locally installed plugins even without network access
- **Wi-Fi indicator** — the main dialog shows whether Wi-Fi is currently on
- **Disable / enable** — turn an installed plugin off without deleting it (KOReader's own plugin-disable mechanism; takes effect after a restart)
- **README viewer** — read a plugin's README before installing, cached to disk so reopening it later doesn't re-download it
- **Ignore a version** — hide one specific update until a newer version is released
- **Search & sort** — filter the plugin list by name, or sort by name/status (tap the magnifier to filter, hold it to change sort)
- **Discover plugins** — search GitHub for third-party KOReader plugins (tagged `koreader-plugin`) and install them directly, outside the koreader-plugins repository
- **Patches** — discover, install, update, disable/enable, and remove KOReader user patches (`koreader/patches/`) from GitHub, the same way appstore.koplugin does

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
| Load/refresh the plugin catalogue and update everything outdated | Tap **Update** |
| Browse every plugin (installed and available) | Tap **Plugin list** |
| Install a new plugin | In the plugin list, tap a plugin in the *Available* section → **Install** |
| Update a single plugin | Tap a plugin showing `v1.0 → v1.1` → **Update to v1.1** |
| Ignore a specific update | In that same dialog → **Ignore vX.Y** (undo from **Ignored updates…**) |
| Disable/enable a plugin without deleting it | Tap an installed plugin → **Disable**/**Enable** |
| Read a plugin's README | Tap a plugin → **README…** |
| Remove an installed plugin | Tap any installed plugin → **Remove** → confirm |
| Filter/sort the plugin list | Tap the magnifier (top-left of the list) to filter by name; hold it to toggle name/status sort |
| Find third-party plugins on GitHub | Tap **Discover plugins…** |
| Check a `(GitHub)` plugin for updates | Tap it in the plugin list → **Check for update** (or **Reinstall** to force a fresh copy regardless of version) |
| Ignore a specific update for a `(GitHub)` plugin | In the **Check for update** dialog → **Ignore vX.Y** (undo from **Ignored updates…**, same as manifest plugins) |
| Link a `(local)` plugin to a GitHub repo, to enable update checks | Tap it in the plugin list → **Link to GitHub repo…** → enter `owner/repo`, or **Search GitHub…** to pick one from a live search instead of typing it |
| Undo a link | Tap a `(GitHub)` plugin → **Unlink** (it becomes `(local)` again; files are untouched) |

After installing, updating, removing, or (de)disabling a plugin, **restart KOReader** for the change to take effect.

### Sections (Plugin list)

| Section | Contents |
|---------|----------|
| *Installed* | Plugins found both locally and in the repository. Shows a `→ vX.Y` arrow when an update is available, and a `[DISABLED]` tag when disabled. |
| *Installed (not in repo)* | Plugins installed locally that are not listed in the repository. Tagged `(GitHub)` and offered **Check for update**/**README…**/**Unlink**/**Remove** if a source repo is known (installed via Discover, or manually linked); tagged `(local)` and offered **Link to GitHub repo…**/**Remove** otherwise. |
| *Available* | Plugins in the repository that are not yet installed. |

## How it works

The plugin manager downloads a `manifest.json` file from the repository root. This file lists every available plugin along with its version and the individual source files it contains. Files are then fetched one by one from `raw.githubusercontent.com` and written directly to the KOReader `plugins/` directory.

Two shared libraries exist for plugins that vendor common code instead of duplicating it: `game-common` (ScreenBase-based games) and `sudoku-common` (BaseScreen-based sudoku variants — a different, incompatible API). A plugin's `common_lib` field in `manifest.json` names which one it needs. The named library is downloaded automatically the first time any plugin that depends on it is installed, and copied into that plugin's `common/` folder (a real copy, never a symlink, so it survives on any device); it's refreshed on every install/update to guarantee it's never stale.

Files are fetched with a short pacing delay between requests, and a 429 (rate limit) from `raw.githubusercontent.com` is retried with backoff rather than failing the whole update — useful during a bulk Update/Reinstall run that touches every installed plugin.

## Discover plugins (third-party repos)

**Discover plugins…** is a separate path from the rest of Plugin Manager: instead of reading `manifest.json`, it searches GitHub itself for repositories tagged with the `koreader-plugin` topic, using the public [Search API](https://docs.github.com/en/rest/search/search#search-repositories).

This topic is self-tagged by repo owners and plenty of real plugins never set it (this fleet's own repositories included), so search also independently checks for `.koplugin` in the repo *name* and merges both result sets — the same trick appstore.koplugin uses. A result is only kept if its repo name ends in `.koplugin`, or its description mentions "koreader"/"koplugin" — this filters out the occasional unrelated repo that happens to carry the topic, though it isn't perfect. It doesn't matter much either way: **Install** always validates the archive actually contains a `_meta.lua` before touching your `plugins/` folder, and refuses cleanly otherwise.

- Tap the magnifier to search by name/description; hold it to switch between sorting by stars and by last-updated. Reopening **Discover plugins…** from the main menu keeps whatever search text and sort you last used, so if a search text you no longer want is stuck (e.g. it now turns up nothing), use the "Clear filter" option offered right there when a search returns no results.
- Type `user:NAME` in the search box to browse every `.koplugin` repository owned by one GitHub account instead — useful for a specific author's plugins, since not everyone (including this fleet's own repositories) sets the `koreader-plugin` topic. This mode doesn't use the topic at all, so it isn't affected by the topic search's noise or its 10 requests/minute limit.
- Tapping a result shows its description, star count, and **Install** / **README…** actions.
- **Install all N shown…** (shown once there are 2+ results) installs every currently listed repository one at a time, with one final summary. Handy paired with `user:NAME` to grab everything from one account in one go. Each install is a separate download against GitHub's *general* API (60 requests/hour unauthenticated) — for a large batch, set a token first (see **Configuration**) or you may hit that limit partway through.
- **Install** downloads the repository's zipball, extracts the plugin (detected by locating `_meta.lua` inside the archive) straight into `plugins/`, and asks for a restart. The source repo (owner/name) is remembered, keyed by the plugin's id.
- The install folder is derived from the repository's own name, so a same-named repo from a *different* owner (or one of this fleet's own `manifest.json` plugins) could otherwise collide with something already installed there. Before overwriting anything, Install checks what's currently in that folder and, if it isn't the exact same repo already tracked there, shows what it found (name, version, source) and asks for confirmation. This applies to **Install all…** too — it pauses on each conflict rather than overwriting silently, so a large batch may need a few taps along the way.
- Plugins installed this way aren't in `manifest.json`, so they show up under *Installed (not in repo)* in the plugin list afterwards, tagged `(GitHub)`. Update tracking there works differently from the repository's own plugins: tap the plugin → **Check for update** fetches `_meta.lua` from the repo's default branch on demand and offers to reinstall if its version is newer — there's no automatic background check or bold "update available" marker like manifest plugins get.
- Only install repositories you trust: this downloads and runs arbitrary third-party code.

GitHub's search API has a very low unauthenticated rate limit (10 requests/minute), and every non-`user:` search or "Load more" tap uses **two** of those requests (topic search + name search); the general API used for `user:NAME` browsing and for every install is more generous (60/hour) but still easy to exceed with many installs back to back. If you hit either, see **Configuration** below.

## Patches

**Patches…** in the main dialog manages KOReader user patches — numbered `*.lua`
files in `koreader/patches/` that KOReader applies at startup (see
`frontend/userpatch.lua` in the main koreader checkout) — the same way the rest
of this plugin manages `.koplugin` plugins, and the same feature
[appstore.koplugin](https://github.com/omer-faruq/appstore.koplugin) offers.

- **Discover patches…** searches GitHub for repositories tagged
  `koreader-user-patch`, merged with a name/description fallback search (same
  two-query strategy as Discover plugins), since plenty of real patch
  repositories never set that topic either. Tapping a repository lists every
  patch file it contains — read from its root, or from a top-level `patches/`
  subfolder if it has one (both conventions exist in the wild) — with
  **Install**, **README…**, or **Install all N patches…** for the whole
  repository at once.
- **Installed patches** lists everything currently in `patches/`, tagged
  `(GitHub)` if it was installed from here (enabling **Check for
  update**/**Reinstall**/README/**Unlink**) or `(local)` otherwise.
  **Disable**/**Enable** renames the file to/from `<name>.lua.disabled` —
  KOReader's loader still matches the numbered prefix but skips anything not
  ending in `.lua`, so the patch stops running without being deleted.
- Patches carry no version metadata, so update checks compare the file's
  GitHub blob SHA against the one recorded at install time, rather than a
  version number.
- **Enable/Disable all patches** toggles KOReader's own global patch switch
  (the same one behind `patches/.patches_disabled`), independent of any
  individual patch's own enabled state.
- As with Discover plugins, only install patches from sources you trust: a
  patch is arbitrary Lua code that runs with full access to KOReader.

## Configuration (optional GitHub token)

To raise the Discover feature's GitHub API rate limit, copy `pluginmanager_configuration.sample.lua` to `pluginmanager_configuration.lua` (same folder) and set a GitHub personal access token:

```lua
return {
    github_token = "ghp_your_token_here",
}
```

Use a **classic** token (Settings → Developer settings → Personal access tokens → Tokens (classic)); GitHub's search API rejects fine-grained tokens outright. No scopes are required for searching/reading public repositories. `pluginmanager_configuration.lua` is gitignored and never leaves your device.

## For developers: releasing an update

1. Bump `version` in the plugin's `_meta.lua`.
2. Update the matching `version` field in `manifest.json` at the repository root.
3. If new source files were added to the plugin, add them to the `files` array in `manifest.json`.
4. Commit and push to `master`. The plugin manager always fetches from the `master` branch.

## Requirements

- KOReader with network access (Wi-Fi or mobile data)
- `ssl.https` and `ltn12` (bundled with KOReader on all supported devices)
- `rapidjson` for JSON parsing (bundled with KOReader)
- `ffi/archiver` for extracting Discover's zip downloads (bundled with KOReader)

## Localization

English is the plugin's source language and needs no translation file: whenever KOReader's UI language isn't French, every string falls straight through to its original English text via `i18n.lua`'s gettext fallback. French translations live in `i18n_fr.lua`, a flat table of `{ ["English source string"] = { fr = "..." } }` entries, merged in at startup. To add another language, add a matching `i18n_<code>.lua` file and load it the same way `i18n_fr.lua` is loaded in `main.lua`.

## License

GPL-3.0
