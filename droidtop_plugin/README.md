# droidtop_plugin -- the plugin-core wrapper

This folder, `lib/droidtop_plugin_main.dart`, `lib/droidtop_plugin_logic.dart`,
`test/droidtop_plugin_logic_test.dart` and the `droidtop-plugin-bundle` job in
`.github/workflows/pr-checks.yml` are the ENTIRE plugin-core patch. Everything
else in this repo is romgi's own code, unmodified, per the branch model in this
repo's own git history (`plugin-core` holds only this wrapper; `plugin/<line>`
is a fork branch with plugin-core merged in).

## What the plugin gives droidtop

A `flutter_embed` plugin, plugin API contract 2 (droidtop `docs/plugin-api.md`
1.6 and 1.7), id `bi0shacker001.romgi-<line>`.

| Extension point | What it does |
| --- | --- |
| `library.sources` | The Get games flow. `form`: search field, platform and region pickers (the platform is preselected to the system the person opened it from, when romgi's index has it). `search`: the local game index, up to 50 results. `detail`: the game's facts, a picker over its direct download sources, one **Download game** job. `acquire` (a job): hands droidtop a download descriptor (below). |
| `ui.settings` | Index status and **Download the game index**, a job with live progress and cancel. |
| `ui.main` | romgi's own app (`mainUi` -> `main.dart`'s `main`) on a second engine, for configuration and browsing. |

### Downloading: droidtop does the single files

`acquire` does not transfer anything. It answers `values.download`, the
additive acquire reply (`docs/plugin-view.schema.json`, `acquireDownload`):
`{url, headers, fileName, size}`. droidtop queues that through Android's
DownloadManager (`DownloadJobs`, the "Downloads and installs" list, Droidtop
tracker #181), then places the file in the system's game folder and rescans.
So the plugin never writes a game file, needs no storage permission and no
foreground service, and a lost connection resumes by itself.

- `url` is the index's link; `headers` are romgi's browser-like headers (plus
  the Referer and Origin Myrient wants); `size` is a **cap** (index figure plus
  10%, at least 1 MiB), because the index size is not always exact.
- `fileName` must match `[A-Za-z0-9][A-Za-z0-9._-]*`, so a title like
  `Some Game (USA)` becomes `Some_Game_USA.zip` (the extension is the source's).
- There is no `sha256`: the index has none.

### What is deliberately not offered (and why)

The detail view lists only **direct HTTP(S) links**, and counts the rest as
"torrent or sign-in sources".

- **Torrents**: need romgi's libtorrent glue (`TorrentServiceImpl`), which
  `MainActivity` registers and droidtop's engine host does not.
- **Extraction** of `.zip`/`.7z`: needs `SevenZipServiceImpl`, same reason.
  Files are placed as downloaded; droidtop's scan reads zips for the systems
  that take them.
- **Internet Archive sign-in links**: the login lives in the app's secure
  storage and web view cookies, which the headless engine does not use.
- **Debrid**: its account is configured in the app's own screen (`ui.main`);
  resolving torrents through it is not wired into `acquire` yet.
- **The app's own after-download steps**: 3DS decryption (boot9 and seeddb
  from romgi's settings), Vita licenses and pkg2zip, and archive extraction
  run only in romgi's own downloader (`ui.main`). A droidtop download is
  placed as the source served it, because the acquire reply has no step that
  runs after droidtop has placed the file.

The extensions droidtop's acquire contract needs for these (a post-download
step the plugin supplies, host unpack, several files per result, readable file
names, resumable plugin-run transfers) are proposed in Droidtop/tracker#355,
and the library pickup bug found on the way (a download that finishes after
its page is closed is not scanned) is Droidtop/tracker#354. This wrapper adopts
each extension as it lands.

Closing these needs romgi's two Android services registered through a Flutter
plugin package that `GeneratedPluginRegistrant` calls (droidtop's engine host
only calls that class). Not built: it changes romgi's Android project and has
to be built in CI to be believed.

### Declared permissions (plugin API 4.1)

`net.domains` (the index host raw.githubusercontent.com, plus the debrid,
metadata and artwork APIs romgi's own screen calls) and
`library.folders.write` (the placement droidtop does for a download). Both with
a plain-language reason. Categories and per-call grants (Droidtop tracker #263)
have no contract yet, so these are the flat v2 permission ids; they map onto
categories when that lands.

## The wrapper protocol

- `setMethodCallHandler` first, then `ready` (the flutter_embed readiness
  handshake: droidtop's `onLoad` blocks on it, and a `handle` sent earlier fails
  with a channel-not-registered error).
- `handle`: the contract 2 envelope in, `{ok, data}` or `{ok:false, error:{code,
  message}}` out. Error codes are droidtop's closed set. A search with no index
  answers `FAILED` with a plain sentence; droidtop shows it with an "Open
  settings" row.
- `startJob(jobId, capability, {call: <envelope>})`, `jobProgress`,
  `jobComplete`, `cancelJob` (cancels the index download's token).
- A result's `ref` is only `{slug}`: droidtop caps an action's args at 16 KiB and
  never parses `ref`; `detail` and `acquire` read the entry back from the index.
- Contract 1 (`invoke`, `acquire_content`) is gone: this manifest is contract 2
  only, and droidtop translates nothing for it.

## Files

- `build.sh` -- builds THIS branch's bundle (unsigned) from romgi's own
  `pubspec.yaml` and `android/` project, pointed at
  `lib/droidtop_plugin_main.dart` with `--target`. The plugin id comes from the
  branch (`plugin/<line>` -> `bi0shacker001.romgi-<line>`). The payload is
  `lib/<abi>/libapp.so`, `dex/classes*.dex` and `flutter_assets/`.
  **`dex/` matters**: romgi's Flutter plugin packages (sqflite, path_provider,
  shared_preferences) keep their Android half there with the generated
  `GeneratedPluginRegistrant`, which droidtop's engine host loads and calls.
  Without it the game index cannot open and every search fails.
- `sign.sh` -- signs `build.sh`'s output with the repo's own key (origin
  `bi0shacker001`, independent of droidtop's official trust ring) and packs
  `<id>.droidplugin.tar.xz` (`lib`, `dex`, `flutter_assets`).
- `manifest.template.json` -- the shared manifest shape; `build.sh` fills in
  `id`, `label`, `runtimeVersion` and `payload`, and in CI stamps the
  declared `version` as `<declared>-<run number>` (`DROIDTOP_PLUGIN_BUILD`,
  Droidtop/tracker#126), so no two builds publish the same version string.
  Bump the declared version with every change to the wrapper or the line.

The runtime pin in `build.sh` (`RUNTIME_VERSION`) and the Flutter SDK in the CI
job must stay equal to droidtop's `flutter-runtimes.json`; a different engine
makes droidtop refuse the bundle at load.

## Building and installing

CI builds and signs it: every push runs `droidtop-plugin-bundle`, which signs
with the repository secret `PRIVATE_PLUGIN_SIGNING_KEY` and publishes the
rolling release `build-<branch>` carrying `<id>.droidplugin.tar.xz` and
`droidtop-plugin-key.json`. In droidtop: Settings, Plugins, Keys you trust, add
this repository (private repositories need the GitHub token set in Accounts and
sources), then install the bundle from the release and approve it.

## Tests

`test/droidtop_plugin_logic_test.dart` covers the descriptor (file names, size
cap, headers, link filtering) and the view documents. The channel code in
`droidtop_plugin_main.dart` is not unit-tested; it was checked by reading
against droidtop's `FlutterDroidtopPlugin` and `FlutterEngineHost`, and needs a
rig run (install the bundle, open Get games for a system, search, download).
