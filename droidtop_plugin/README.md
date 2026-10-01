# droidtop_plugin -- the plugin-core wrapper

This folder plus `lib/droidtop_plugin_main.dart` and the additive
`NotificationService.silent()` factory in `lib/services/notification_service.dart`
are the ENTIRE plugin-core patch. Everything else in this repo is romgi's
own code, unmodified, per the branch model in this repo's own git history
(`plugin-core` holds only this wrapper; `plugin/<line>` is a fork branch
with plugin-core merged in).

- `build.sh` -- builds THIS branch's plugin bundle (unsigned), using
  romgi's own real `pubspec.yaml`/`android/` project pointed at
  `lib/droidtop_plugin_main.dart` via Flutter's `--target` flag, so no
  per-line source or manifest edits are needed: the plugin id is derived
  from the current branch name (`plugin/<line>` -> id
  `bi0shacker001.romgi-<line>`).
- `sign.sh` -- signs `build.sh`'s output. Private plugin, own
  independent P-256 key (origin `bi0shacker001`), not the official
  droidtop trust ring, not derived from droidtop's own root. CI runs
  this step and publishes only the signed bundle -- see
  `droidtop-plugin-key.json` at the repo root for the matching public
  half, which droidtop reads from here directly.
- `manifest.template.json` -- the shared manifest shape (capabilities,
  ABIs, runtime kind); `build.sh` fills in `id`/`label`/`runtimeVersion`/
  `payload` per build.

See droidtop's own `docs/SPEC.md` 12a for the `flutter_embed` plugin kind
this bundle installs as, and this repo's `PLUGIN-PLAN.md` for the
integration surface (`RomDatabaseService.search`, `DownloadService.
addDownload`/`downloadStream`, `StorageService.getPlatformDirectory`)
`lib/droidtop_plugin_main.dart` calls into.

Contract 2 extension points implemented: `library.sources` provides a
query/platform/region form, local-index search results, a detail page with a
link picker, and an acquire job; `ui.settings` reports game-index status and
provides a progress-reporting job to download the index. Both jobs use the
contract 2 `startJob` envelope. The legacy `acquire_content` invoke/download
path remains available for contract 1 manifests, and `cancelJob` forwards to
`DownloadService.cancelDownload`.

Not implemented: `metadata_source` (romgi as a scrape source
for droidtop's own scanner) and `library_action`/`app_status` -- both are
declared as future capabilities in PLUGIN-PLAN.md, not built here.
