# Changelog

All notable changes to this project will be documented in this file.

## [1.7.4] - 2026-11-10

### Added
- The "Two readers" category (FR « À deux liseuses ») in the catalogue's
  category filter, for the new games played with two readers.

## [1.7.3] - 2026-11-04

### Fixed
- Plugins taken out of the catalogue (Mots fléchés/arrowwords, Kakuro, Start
  menu, Boggle party, Double or nothing) could stay on the reader for good:
  once gone from the plugin list they were treated like any third-party
  plugin -- never updated, skipped by "Remove all" -- while KOReader kept
  loading them at every start. An old arrowwords left that way made every
  game crash when opened ("getGutter (a nil value)"). Plugin Manager now
  finds them (the catalogue's new `retired` list, or a built-in one when the
  catalogue is older or not downloaded yet), says so when it checks for
  updates, and offers "Remove outdated plugins (N)…" first on its home
  screen, which deletes their folders for real and checks they are gone. A
  folder that lost its _meta.lua but still has its code is found too. The
  plugin list tags them "(retired)".
- The `_skeleton` developer template is found and offered for removal the
  same way, and is never installed: refused from the catalogue, from an
  import or a bulk install, and from Discover (where it is no longer
  listed).

## [1.7.2] - 2026-11-04

### Changed
- Opening or closing a book no longer re-reads Plugin Manager's settings
  file and decodes the cached plugin list again. KOReader starts a new copy
  of every plugin each time it switches between the file browser and a book,
  and Plugin Manager's start was the most expensive of all (about 230 KB
  read and decoded, twice per book). The settings and the decoded list are
  now kept once and shared. No memory leak was found: opening and closing
  Plugin Manager or a book 40-120 times in a row leaves memory flat.
- Uses less memory: most of Plugin Manager, and the cached plugin list,
  load the first time you use it, not when KOReader starts (about 870 KB
  less at startup in English). Only the translations of your language are
  loaded, none in English.

## [1.7.1] - 2026-11-04

### Fixed – translations
- The search dialogs' "Clear" button uses its own English key ("Clear
  search", still "Effacer" in French). It shared "Clear" with the game
  plugins, which translate it "Effacer tout".
- German category names now match the Tools → Games menu: "Gruppenspiele"
  (was "Party & Quiz") and "Andere" (was "Sonstige").
- "All categories" reads "Toutes catégories" in French, as in Pictionary
  (was "Toutes les catégories"; both shared one entry).

## [1.7.0] - 2026-11-03

### Fixed
- Install everything / Update / Reinstall all no longer seem to freeze. A
  full run used to download all ~110 plugins file by file (over a thousand
  separate downloads) with the screen frozen on each plugin; on a slow reader
  it took long enough for the reader to go to sleep mid-way, which cut Wi-Fi
  and stalled the run.

### Changed
- Much faster installs: each plugin now comes as one download (the ready
  zip the repository publishes for it), checked as a whole against the
  plugin list's SHA-256 and size, with every `.lua` still compile-checked
  before anything is installed. The shared libraries are refreshed the same
  way. On a test of 11 plugins: 4 s instead of 65 s. If a zip is missing,
  does not match (for example just after a release, while GitHub still
  serves the previous one) or is damaged, that plugin is downloaded file by
  file as before. Single-plugin installs and updates use it too.
- One progress window for the whole run ("12/110 · Boggle") instead of a new
  message per plugin, with a **Stop** button: the plugin in progress is
  finished, then the run ends with its summary ("Stopped after 12/110").
  With Install everything, Stop also skips the patches.
- The reader stays awake during Update, Reinstall all, Install everything
  and Import (no automatic sleep or standby until the run is over), then
  sleeps normally again.
- Downloads give up after a time limit (15 s without any progress; 20 s
  for a file, a minute or more for a plugin zip, depending on its size) instead of waiting on a dead connection,
  and the run carries on with the next plugin.

## [1.6.0] - 2026-10-30

### Added
- Install everything: a home-screen entry that runs Update (every catalogue
  plugin not installed plus every update, ignored versions and
  `min_koreader` respected) and then installs every patch file of the
  repositories in the manifest's new optional top-level `patch_repos`
  field, after one confirmation with the counts, ending on one summary and
  one restart prompt. A patch already at the repository's content (git blob
  SHA) is not downloaded again, a disabled one is left disabled, and a
  repository that cannot be listed is reported without hiding the plugin
  results. A manifest without `patch_repos` makes it Update with a
  confirmation.
- Discover patches: `user:NAME` lists one GitHub account's patch
  repositories (topic `koreader-user-patch`, "patch" in the name, or a
  description naming KOReader and patches), one general-API request per
  100 repositories, then the usual per-repository patch list. The search
  dialog says so.
- `pmlogic.lua`: `ownerQuery`, `isOwnerPatchRepo`, `patchRepos`,
  `planPatchInstalls`, `everythingCounts`, specced in
  `test_pmlogic_spec.lua`; the whole flow is driven end to end by
  `test_install_everything_spec.lua`.

### Changed
- A shared-library error during a bulk run no longer stops Import's GitHub
  installs (or Install everything's patches): the error heads the final
  summary instead.
- "Install all N patches" shows per-patch progress (it shares Install
  everything's patch loop).

## [1.5.0] - 2026-10-30

### Added
- Restart now: every change that needs a restart (install, update,
  enable/disable, patches, restore) offers KOReader's own "Restart now /
  Restart later" box (`UIManager:askForRestart`) instead of only saying so.
  Bulk runs (Update, Reinstall all, Install all, Import) ask once, at the end.
- The home screen's Update entry shows the number of updates waiting
  ("Update (3)"), from the cached plugin list -- no network. The count, the
  silent background check and the Update button now share one definition
  (`pendingUpdates`), so they can no longer disagree.
- Screenshot: the available- and installed-plugin dialogs show the plugin's
  README screenshot from its `images/` (the installed copy when there is one,
  otherwise downloaded once and cached).
- What's new: before updating, shows only the CHANGELOG.md sections newer
  than the installed version and up to the offered one (`[Unreleased]`
  skipped; the whole file when its headings cannot be read), with an Update
  button.
- Categories: the plugin list is split into sections by the manifest's new
  `category` field (labels translated), with a category filter in the search
  dialog. Sort modes and the name filter work as before; uncategorised
  plugins go under "Other"; a manifest without categories keeps the flat list.
- Restore previous version: an update keeps the replaced version in
  `plugins/.pluginmanager-backup/<plugin>/` (one per plugin), and the
  installed-plugin dialog offers to swap it back (path-guarded renames,
  restart offered, the backed-out version ignored). Shared libraries and
  GitHub-installed plugins are not rolled back.
- Integrity check: installs are staged in `plugins/.pluginmanager-staging/`
  and committed only once every file is in. Every `.lua` must compile, and,
  when the manifest carries `sha256`, every file must match it -- a
  mismatch is re-downloaded once, then accepted only when the downloaded
  `_meta.lua` is at least the manifest's version (upstream ahead of the
  manifest), never when older. A failed install leaves the installed
  version untouched instead of half-overwritten. Shared libraries are
  downloaded and checked in full before the first file is written.
- Minimum KOReader version: the manifest's optional `min_koreader` flags a
  plugin in the list and its dialog, asks before installing it, and makes
  Update / Reinstall all / Import skip it with a summary line.
- Export / import: "Export installed list" writes
  `pluginmanager-export.json` (installed repository plugins plus
  GitHub-linked ones) to KOReader's data directory; "Import list…" shows what
  it will install and installs it through the bulk path.
- `pmlogic.lua`: the decision logic behind all of the above, free of KOReader
  dependencies; specced by `test_pmlogic_spec.lua`, with the install paths
  driven end to end by `test_install_integrity_spec.lua`.

### Changed
- The main menu and the Patches menu open full screen, like the plugin list
  and every game, instead of as pop-ups. Lists opened from them come back to
  them when closed, rather than dropping out to the book.
- Installing a single plugin now always offers a restart, not only when Plugin
  Manager updated itself: the plugin's code is not loaded until then.
- `installPlugin`/`ensureCommon` resolve the manifest's `dir` through
  `PathGuard.pluginPath` before using it, like removal already did.

### Fixed
- A Plugin Manager self-update deleted `pluginmanager_configuration.lua`, and
  with it the user's GitHub token: the clean-up of files no longer listed in
  the manifest removed it like a stale source file. Files a user creates in a
  plugin's folder are now kept.

### Requires
- Regenerate `manifest.json` with the updated `update_manifest.py` before
  releasing this version: its `files` list for pluginmanager must include the
  new `pmlogic.lua`, or the self-update ships a `main.lua` that cannot load.
  The `sha256`/`category`/`min_koreader` fields are optional: this version
  works with a manifest that has none of them.

## [1.4.5] - 2026-10-07

### Fixed
- Reinstall All now really re-downloads the shared libraries, as its prompt
  has always promised. `ensureCommon()` short-circuited on the bundle's
  `.version` stamp, which records a version and not integrity: a
  `game-common`/`sudoku-common` truncated by a mid-write crash or a
  half-finished run kept a perfectly current stamp and was skipped by the one
  action whose purpose is to fetch everything again. `installPlugin()` then
  copied that stale bundle into every consuming plugin's `common/`, so
  Reinstall All propagated the damage instead of repairing it. The gate is
  kept for Update, which has nothing to re-download.

### Added
- `test_bulk_install_spec.lua`: drives the real `_doFullUpdate` /
  `_doFullReinstall` against a sandbox plugins/ tree and a fake
  raw.githubusercontent, covering both bulk paths end to end.


## [1.4.4] - 2026-10-07

### Fixed
- Bulk update/reinstall now asks for a restart whenever it installed anything,
  not only when Plugin Manager had updated itself. KOReader loads plugin Lua
  once at startup, so every file a bulk run writes stays inert until a
  restart -- but the run ended on a bare "N plugin(s) updated" with no hint of
  that. Updating the whole fleet and then opening a game showed the *previous*
  version's behaviour, which reads exactly like an update that never shipped.
  The single-plugin install path had always prompted; the bulk path now
  matches it.


## [1.4.3] - 2026-10-02

### Fixed
- `require("i18n")` -> `lrequire("i18n")`. `package.loaded` is keyed by module
  name alone, so every `require("i18n")` on the device resolves to one module
  and the first plugin loaded wins it. Every plugin's `i18n_fr.lua` merges
  into that one shared table, where plugins silently overwrite each other's
  translations. This plugin is standalone -- no `common/`, and its strings are
  its own -- so it had no business taking that slot or merging into the game
  plugins' table, where its `Clear` ("Effacer") was overwriting theirs
  ("Effacer tout"), already the translation of `Erase`, leaving two identical
  buttons in every game.

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
