# Changelog

All notable changes to this project will be documented in this file.


## [1.4.2] - 2026-10-01

### Fixed
- KOReader offered no way to delete this plugin's settings. The settings path
  was computed inline rather than stored on the instance, and `PluginLoader`
  reads `instance.settings_file` to decide whether to show "Delete plugin
  settings" at all (2026.07, PR #15240). The option simply never appeared, and
  deleting the plugin left ``pluginmanager.lua`` behind.
  `init()` now resolves it too: it was only reached on the first `getSetting()`,
  which is later than KOReader builds the plugin dialog.

## [1.4.1] - 2026-09-30

### Fixed
- Guard the file paths that come from `manifest.json`'s `files` field and from
  a downloaded archive. `pathguard.lua` was written for the `dir` field, whose
  paths arrive over the network; the same reasoning had never been applied to
  these three sites, which built a write path out of a string chosen
  elsewhere. An entry of `../../evil.lua` wrote wherever it liked -- for the
  archive that is Zip Slip, and the prefix test already there protects nothing
  against it, since `myplugin/../../evil.lua` does start with `myplugin/`.
- Quote the `mkdir -p` fallback. `shellQuote` was called for the neighbouring
  `rm -rf` and missed here -- same file, same no-lfs branch, same source.

None of this was remotely triggerable: the manifest is served from the
project's own GitHub repository over HTTPS. These were missing guards, not
open holes.

### Added
- `PathGuard.filePath(root, rel)`, which builds the path and refuses it unless
  it landed inside `root`. The spec goes from 15 cases to 29; the last checks
  that `filePath` never returns a path `isWithin` would refuse, so the two
  guards cannot drift apart.

## [1.4.0] - 2026-09-30

### Fixed
- **Tightened what this plugin is allowed to delete.** The guard around
  `rm_rf` was `path:find(_plugins_dir, 1, true)` — a *substring* test, not a
  prefix one. It therefore also let through any sibling directory whose name
  merely began with the plugins directory (`plugins-backup`, `plugins_old`,
  `plugins.bak`) and any path that happened to contain it further along. It is
  now an anchored prefix test against the plugins directory with a trailing
  separator, and the directory itself is no longer a deletable target.
- Paths containing a `..` segment are refused outright. They are built from
  `manifest.json`'s `dir` field, which arrives over the network, and were not
  checked for it.
- The directory name is now validated where the path is built, not only where
  it is deleted: a name that is not one plain path segment is refused and the
  removal is reported as declined rather than silently doing nothing.
- The no-`lfs` fallback ran `os.execute("rm -rf " .. path)` with the path
  unquoted, so one containing a space would have handed `rm -rf` two targets
  instead of one. It is single-quoted now.

### Added
- `pathguard.lua`, holding that logic on its own with no KOReader dependency,
  and `test_pathguard_spec.lua` covering it — 15 cases including every sibling
  and `..` shape above. This plugin is the only one in the collection that can
  destroy a user's files and it had no tests at all.

## [1.3.0] - 2026-08-05

### Added
- **Patches…**: manage KOReader user patches (`koreader/patches/`) the same
  way this plugin already manages `.koplugin` plugins, mirroring what
  appstore.koplugin offers. Discover patch repositories on GitHub (topic
  `koreader-user-patch`, merged with a name/description fallback search,
  same strategy as Discover plugins), browse and install individual patch
  files or a whole repository's worth at once, then track installs with
  Check for update/Reinstall/README/Unlink and per-patch Disable/Enable
  (renames to `<name>.lua.disabled`, which KOReader's own loader skips).
  Since patches carry no version metadata, updates are detected by comparing
  the file's GitHub blob SHA against the one recorded at install time.
  A new "Enable/Disable all patches" toggle controls KOReader's own global
  patch switch independently of individual patch state.

## [1.2.4] - 2026-08-04

### Added
- Plugin list: a plugin installed via Discover-link (tagged `(GitHub)`) now
  shows an update badge (`vX→vY`, bold, sorted to the top) the same way
  manifest-tracked plugins already do. Its remote version is refreshed
  quietly when pressing "Update" (already a network action taken
  periodically), then cached, so opening the plugin list itself stays
  instant and works offline — no per-open network call.

## [1.2.3] - 2026-08-04

### Fixed
- Six loops used `_` as their discard variable, shadowing the module-level
  gettext alias (`local _ = require("i18n")`). Any `_(...)` call inside
  those loop bodies then tried to call the loop's numeric index/key instead
  of the translation function, crashing with "attempt to call local '_' (a
  number value)" in showIgnoredDialog, the Discover results list,
  showPluginList, and both removed/renamed-plugin summaries in
  `_runBulkInstall`.

## [1.2.2] - 2026-08-04

### Added
- Discover plugins: results already installed locally are now marked
  (`Installed vX`), and are checked against their remote `_meta.lua` for a
  newer version (`vX→vY`, shown in bold), the same way the main installed
  list already flags updates. Only fires for results actually already
  installed, and via raw.githubusercontent.com (already paced/retried),
  not api.github.com — doesn't touch the search/install rate limit.

## [1.2.1] - 2026-08-04

### Fixed
- "Remove all…" deleted every `*.koplugin` directory it found with a
  `_meta.lua`, including KOReader's own built-in plugins, not just the ones
  this fleet's manifest installed. It now fetches the manifest and only
  removes plugins actually listed in it, like Update/Reinstall all already
  do.

## [1.2.0] - 2026-08-04

### Added
- Wi-Fi status indicator (✓/✗) in the main dialog.
- Disable/enable an installed plugin without deleting it, using KOReader's
  own plugin-disable mechanism.
- Per-plugin README viewer, cached to disk so reopening it later (or
  offline) doesn't re-download it; a "Refresh" button forces an update.
- "Ignore this update" for a specific version, with an "Ignored updates…"
  dialog to review/undo. Works for both manifest.json plugins and
  GitHub-linked ones.
- Filter and sort the plugin list: tap the magnifier to filter by name,
  hold it to toggle name/status sort.
- **Discover plugins…**: search GitHub for third-party KOReader plugins by
  topic tag and by `.koplugin` name pattern (merged, like appstore.koplugin
  does), or browse a specific author's repos directly with `user:NAME`.
  Supports installing one at a time or all shown results in one go, and
  warns before overwriting anything already installed under the same
  folder name from a different source.
- Link an untracked locally-installed plugin to a GitHub repo (manually by
  `owner/repo`, or by picking one from a live Discover search), enabling
  "Check for update"/"Reinstall"/README for it; Unlink to undo.
- Optional GitHub personal access token
  (`pluginmanager_configuration.lua`, see the sample file) to raise
  Discover's GitHub API rate limits.

### Fixed
- Crash ("attempt to index a userdata value") when a GitHub repository had
  no description: rapidjson decodes JSON `null` as a sentinel value that
  isn't a plain Lua nil, which needs explicit handling before treating a
  field as a string.
- The plugin list's and Discover's filter dialogs could fail to take
  keyboard input: the full-screen list underneath was never closed before
  opening them, unlike every other action in those menus.

### Removed
- "Manage sources…" (support for merging in additional manifest.json-format
  repositories). Discover plugins' broader, zero-setup GitHub search covers
  the same need far better in practice, since nothing else exists that
  actually follows this project's manifest.json schema. The multi-source
  merge/fetch logic was simplified away accordingly.

## [1.1.26] - 2026-07-29

### Added
- "Remove all…" button in the main dialog to bulk-remove every installed
  plugin in one step, with confirmation. Plugin Manager's own directory is
  always kept so it remains available to reinstall everything afterwards.
