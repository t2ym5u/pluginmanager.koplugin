# Contributing

This plugin is part of the [koreader-plugins](https://github.com/t2ym5u/koreader-plugins)
collection for [KOReader](https://koreader.rocks/). See that repo's
[docs/README.md](https://github.com/t2ym5u/koreader-plugins/blob/main/docs/README.md)
for the full plugin list and install instructions.

## Reporting a bug or requesting a feature

Open an issue here. If it's not specific to this plugin (installation,
Plugin Manager, shared libraries), open it in the
[koreader-plugins](https://github.com/t2ym5u/koreader-plugins/issues) monorepo instead.

## Submitting a change

1. Fork this repo and make your change.
2. If a `spec/` directory exists, run `busted spec/` and make sure it passes.
3. Test the change in KOReader itself if you can, not just the test suite.
4. Open a pull request describing what changed and why.

Versioning and releases (git tags, `dist/` zips, the shared `manifest.json`
in koreader-plugins) are handled by the maintainer after merge — you don't
need to bump `_meta.lua`'s version yourself unless asked.

Each plugin here is released under its own licence — see `LICENSE` in this repo.
