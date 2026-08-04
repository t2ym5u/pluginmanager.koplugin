# Changelog

All notable changes to this project will be documented in this file.

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
