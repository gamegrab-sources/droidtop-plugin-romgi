# romgi as a droidtop plugin

Private plan. Upstream: https://github.com/caprado/romgi (MIT). Owner's
installed build: `com.bi0shacker001.romgi` (see
`/root/coordination/romgi-integration.md` for the prior JSON-integration
groundwork, now superseded as the goal here -- the owner wants a real plugin
built FROM romgi's own code, not a launch-the-real-app intent).

**Plugin model this plan is written against (2026-09-25):** droidtop plugins
run in **droidtop's own process/context**, never through enginehost. A
plugin is Python, a native Kotlin/`.so` bundle (arm64-v8a + x86_64), or
another kind droidtop's host adds support for. The sandbox exists for
stability, not security. Root is an optional enhancement only, never
required, never the default path.

## What it would contribute

A search/download surface inside droidtop's own systems: search romgi's
sources for a system, show results with progress, and save straight into
that system's real destination folder -- plus, once that exists, a
downloads-status tile and per-result actions (retry, cancel, pick a mirror).
This is a strict upgrade over the earlier JSON `acquire_content` plan: that
could only launch romgi's home screen with ignored extras; a real plugin
lets droidtop render romgi's search results itself and drive the download
without ever switching apps.

## The real question: how does Dart/Flutter code become a droidtop plugin

romgi is Flutter (Riverpod, dio, sqflite; `lib/services/{debrid,metadata,torrent}`
plus a local scraped index in `db/`). Neither standing plugin kind (Python,
native Kotlin/`.so`) accepts Dart source directly, so every route below
either reuses romgi's actual code through a new mechanism or re-expresses
its logic in another language. Weighed on effort, how well it keeps riding
this repo's daily upstream sync, and APK size:

### A. Flutter module -- embed a Flutter engine in the plugin runner, reuse the Dart code behind a bridge

A new plugin kind: droidtop's plugin host embeds a Flutter engine
(`libflutter.so`, arm64-v8a + x86_64) in the plugin runner process and loads
romgi's actual Dart code -- `lib/services/*`, `lib/models`, `lib/providers` --
compiled to a release AOT snapshot, fronted by a thin plugin-API adapter
package (new code, added to *this* repo, not upstream) that translates
droidtop's plugin calls (search, download, status) into calls on romgi's
existing Riverpod providers, and streams results back over a method channel
instead of rendering romgi's own screens.

- **Effort:** bounded and one-time. The adapter package is new glue code,
  but everything it calls -- the catalog, search, download, sqlite index --
  is romgi's existing, working implementation, untouched. Host-side, this is
  real work (a new plugin kind, an engine lifecycle, a method-channel
  bridge), but it's built once and serves any future Flutter/Dart plugin
  too, not just this one.
- **Upstream sync:** the best of the four routes, by a wide margin. Because
  the reused code is still Dart, `upstream-main` -> `main` merges (the
  workflow this repo already runs daily) keep working exactly as designed --
  upstream commits land as real, mergeable diffs against the same files the
  adapter calls into. A conflict only happens when upstream actually touches
  the same lines the adapter touches, which is rare for glue code sitting
  beside, not inside, romgi's services.
- **APK size:** the real cost. A Flutter engine is several MB per ABI
  (arm64-v8a + x86_64 roughly doubles that), plus the Dart AOT snapshot for
  romgi's own code. This is paid once if the host reuses a single shared
  engine instance for every Flutter-module plugin rather than one engine per
  plugin -- worth stating as a requirement to the plugins agent, not an
  afterthought.

### B. Port core logic to Kotlin

Rewrite `lib/services/{debrid,metadata,torrent}`, the catalog/search logic,
and the download/ROM-management flow as Kotlin, fitting droidtop's existing
native Kotlin/`.so` plugin kind -- no new host capability needed.

- **Effort:** high and, worse, recurring. This is a full reimplementation of
  romgi's actual logic (HTTP clients, parsers, the download state machine,
  the local index) in a different language and typically a different
  HTTP/DB stack (OkHttp vs dio, Room/SQLite driver vs sqflite).
- **Upstream sync:** this is where the route loses. Once ported, the code is
  structurally unrelated to upstream Dart source -- the daily
  `upstream-main` -> `main` merge still succeeds mechanically (it's merging
  Dart files nobody edits on the `main` side), but it stops doing anything
  useful for the plugin itself: every upstream behavior change has to be
  noticed and re-translated by hand, forever. That's a permanent tax working
  directly against the reason this repo has an auto-sync workflow at all.
- **APK size:** best of the four -- plain native code, no extra runtime.

### C. Python port

Same shape as B -- reimplement the same logic in Python instead of Kotlin,
fitting droidtop's Python plugin kind.

- **Effort:** likely somewhat lower than a Kotlin port (Python's more
  permissive for scraping/parsing code, `httpx`/`requests` and `sqlite3` are
  close analogues of dio/sqflite), but it's still a full translation, not a
  reuse.
- **Upstream sync:** the same permanent problem as B -- a translated
  implementation drifts from upstream Dart source immediately and needs
  hand re-porting for every meaningful upstream change.
- **APK size:** good, if droidtop already ships one shared Python
  interpreter for its Python-kind plugins generally -- the marginal cost of
  one more Python plugin is then small. Worse than B only if no shared
  interpreter exists yet and this is the one paying to bootstrap it.

### D. Other routes considered and set aside

- **Dart AOT compiled to a bare native library**, called from Kotlin without
  a full Flutter engine (`dart compile` producing something FFI-callable, or
  a minimal Dart standalone runtime). Would avoid the Flutter-engine size
  cost of route A while keeping route A's upstream-sync advantage. Set
  aside for now because it depends on romgi's actual dependencies (dio,
  sqflite, the platform channels its `pigeons/` already generate for
  seven-zip/torrent native calls) all working outside a Flutter engine,
  which is not a given -- `sqflite` and the torrent/seven-zip pigeon bridges
  are plausibly Flutter-plugin-shaped themselves. Worth a spike if route A's
  size cost turns out to matter in practice, not a starting recommendation.
- **Keep the JSON `acquire_content` intent plan** from
  `romgi-integration.md` as a fallback. Still the right *baseline* -- it
  needs far less work and remains valuable as a "romgi isn't installed as a
  plugin yet" degrade path -- but it's explicitly not the goal here, since
  the owner wants a real plugin built from romgi's code.

## Recommendation: A, the Flutter module

Upstream-sync friendliness is not a nice-to-have for this repo -- the whole
point of the `upstream-main`/daily-merge machinery this fork was built with
is to keep absorbing caprado/romgi's changes with minimal manual work.
Routes B and C both throw that away permanently the moment the port lands:
a rewritten implementation can never again receive an upstream diff as
anything but noise on files `main` no longer really depends on. Route A is
the only one where the sync keeps doing real work indefinitely, and it's
also the only one that doesn't require re-implementing (and therefore
re-testing, re-debugging) romgi's actual download/search logic a second
time -- directly in line with this project's "one mechanism per job, don't
duplicate a working app" rule already applied to the scraper case in
`docs/SPEC.md`. The APK-size cost is real but bounded and shared across any
future Flutter/Dart plugin, unlike B/C's cost, which is unbounded and paid
forever in engineering time.

**Recommended: route A.** Build the plugin-API adapter package in this
repo's `lib/` (or a sibling package under it), calling romgi's existing
providers/services directly; ask the plugins agent for the "Flutter module"
plugin kind described below.

## Root

Not needed for any route. romgi already writes to its destination folder
under its own permissions (`MANAGE_EXTERNAL_STORAGE`); nothing in the search
or download path benefits from root, matching the optional-enhancement-only
rule.

## What it needs from droidtop's plugin API

- **A new "Flutter module" plugin kind**, if route A is picked: an embedded
  Flutter engine (arm64-v8a + x86_64) in the plugin runner process, ideally
  one shared engine instance serving every Flutter-module plugin rather than
  one per plugin, and a method-channel-shaped call/response + streaming
  bridge (for search results and download progress) analogous to whatever
  request/response shape the Kotlin and Python plugin kinds already use.
- **Scoped file access**, not a bare filesystem handle -- the plugin needs to
  write into one system's real destination folder, the same shape droidtop
  already hands ROM launches (a tree URI / scoped grant), not open access to
  storage.
- Beyond that, nothing romgi-specific: once a plugin can register search
  results and a download-progress stream, romgi's own UI patterns (source
  picker, per-result actions) map onto droidtop's existing row/action/status
  conventions with no new capability needed.

## Status update, 2026-09-26 (agent flutterkind)

**Route A is no longer hypothetical.** droidtop's `flutter_embed` plugin
kind is built (droidtop commits `63627015`, `77bb12a4`, `450b96c7` on
`main`): `FlutterRuntimeManager` downloads and verifies the shared
`libflutter.so` runtime; `FlutterDroidtopPlugin` hosts a real
`FlutterEngine` in `:pluginhost` per plugin, bridging droidtop's
`invoke`/`startJob` calls to Dart over one `MethodChannel`
(`dev.droidtop.pluginhost/<pluginId>`) carrying `{"capability", "args"}` in
and `{"ok", "values"|"error"}` back out, JSON-encoded strings both ways. A
sample (`droidtop/samples/plugin-sample-flutter-statustile`) builds,
signs and installs end to end; the one open item is confirming
`flutter_assets` loads correctly from outside the APK on a real device
(`dq-flutterembed-01`, queued) -- see droidtop's own `docs/SPEC.md` 12a for
the full citation trail. **One shared engine instance across plugins was
NOT built** -- each `flutter_embed` plugin gets its own `FlutterEngine`;
only the `libflutter.so` download itself is shared process-wide. That is
enough to satisfy the "don't pay the runtime-download cost per plugin"
concern this plan raised, but not literally "one engine, N plugins."

**Also done 2026-09-26:** this repo's `upstream-main` now tracks the
owner's own fork, `github.com/bi0shacker001/romgi` `main` -- not
`caprado/romgi` directly. Only that fork's `main` is mirrored; no upstream
feature branches. `sync-upstream.yml` and this README's own footer were
updated to match, and `upstream-main` was reset to the fork's tip and
pushed. **The corresponding `upstream-main` -> `main` merge did NOT land**
in this pass: it has real new content (PSVita `pkg2zip`/`zrif` support
among it) and one real conflict, `.github/workflows/pr-checks.yml`,
that this agent's own tooling permissions blocked resolving mid-session
(two separate denials reading/editing that one file while a merge was in
progress -- not a romgi-specific problem, a session/tooling one). `main`
currently has this plan's own re-pointing commit
(`a88a2fa5`) but not yet the fork's newer Dart changes. **Next actual step
for whoever picks this up:** `git fetch && git checkout main && git merge
upstream-main`, resolve the one conflict in `pr-checks.yml` (pick the
fork's CI shape, since upstream is now that fork, not caprado's), commit,
push -- ordinary, no force needed.

**Concrete integration surface for the plugin-API adapter (real, read
from this repo's own `lib/services/` on `main` as of the pre-merge state
above -- names may shift slightly once the pending merge above lands, but
the shape won't):**

- **Search** -- `RomDatabaseService.search({String? query, List<String>?
  platforms, List<String>? regions, bool retroAchievementsOnly, int page,
  int maxResults}) -> Future<SearchResult>` (`lib/services/rom_database_service.dart:339`).
  Maps directly onto `PluginCapability.ACQUIRE_CONTENT`'s query half, and
  onto `METADATA_SOURCE` if droidtop wants romgi as a scrape source too.
- **Download** -- `DownloadService.addDownload({...}) ->
  Future<(AddDownloadResult, DownloadTask)>` plus the broadcast
  `Stream<DownloadTask> downloadStream` (`lib/services/download_service.dart:46`,
  `:199`). This is the real long-running-job shape --
  `DroidtopPlugin.startJob`/`PluginJobProgress.report` should subscribe to
  `downloadStream`, filter by task id, and call `progress.report(...)` per
  update, `progress.complete(...)` on the task's terminal state
  (`DownloadTask` already has whatever status/progress fields the stream
  emits -- not re-read in this pass, check `lib/models/download_task.dart`
  before implementing).
- **Where droidtop's own destination folder plugs in** --
  `StorageService.getPlatformDirectory(String platform) -> Future<Directory>`
  (`lib/services/storage_service.dart:97`) is the one seam
  `DownloadService` actually calls through for "where do I write this
  file". The adapter's job is a `StorageService` subclass/wrapper that
  overrides just this method to return the real folder
  `PluginContext.libraryFolderPath(systemId)` hands the plugin, instead of
  romgi's own app-storage layout -- exactly the "hand over the destination
  folder PATH, plugin writes real files into it" contract §12a already
  specifies, needing no change to `DownloadService` itself.
- **Construction cost, not yet resolved:** `DownloadService`'s constructor
  takes seven required collaborators (`DatabaseService`, `RomDatabaseService`,
  `StorageService`, `NotificationService`, `HostAdapterRegistry`,
  `TorrentService`, `SevenZipService`, `DebridService?`) --
  `lib/services/download_service.dart:92`. Building all seven headless
  (no UI, no real notification channel, `NotificationService` in
  particular -- droidtop has its own status-tile surface and almost
  certainly wants this stubbed to a no-op rather than posting a second,
  competing Android notification) is real, untested work this pass did
  not attempt -- verify each constructor's own requirements before wiring
  it up, don't assume a bare no-arg substitute compiles.

**What this pass did NOT do, so the next one doesn't assume otherwise:**
no Dart adapter code was written or committed to this repo; no manifest
for a real romgi plugin exists; the `upstream-main` -> `main` merge above
is still pending. This addendum is the concrete map for that work, grounded
in flutter_embed actually existing now -- not a restatement of the
four-routes analysis above, which stands unchanged.

## Built and rig-verified, 2026-09-26 (agent romgiplugin)

The plugin-core wrapper is real and installed on the rig. Branch model:
- `upstream-<line>` mirrors the owner's fork (bi0shacker001/romgi) main
  plus its 5 feature branches, 1:1.
- `plugin-core` (based on the common ancestor of every upstream line, not
  any one line's tip, so merging it never drags one line's own content
  into another) holds only: `lib/droidtop_plugin_main.dart` (new file;
  calls RomDatabaseService.search and DownloadService.addDownload/
  downloadStream/cancelDownload unmodified, per the integration surface
  this file already mapped out), an additive
  `NotificationService.silent()` factory, and
  `droidtop_plugin/{build.sh,sign.sh,manifest.template.json,README.md}`
  plus one extra CI job in pr-checks.yml (guarded on
  droidtop_plugin/build.sh existing, so it's a no-op on the mirrored
  upstream branches) -- the fork's own CI is untouched.
- `plugin/<line>` is each upstream line with plugin-core merged in; the
  plugin id (`droidtop.romgi-<line>`) and label are derived from the
  branch name at build time, so no per-line source/manifest edits are
  ever needed.

Capabilities: `acquire_content` only. `invoke(action=search)` (bounded,
fits the 15s watchdog -- it's a local sqlite index, not a network call).
`startJob(action=download)` for the real download with progress
(required droidtop's own `flutter_embed` kind to gain `startJob` support
at all -- built the same day, see droidtop's own docs/SPEC.md 12a). The
destination folder is a `StorageService` subclass overriding just
`getPlatformDirectory`.

**Rig-verified on BlueStacks:** installed plugin/main's signed bundle,
approved it, and it shows "Running - droidtop - Get content" with no
crash -- confirms the Dart entrypoint, romgi's own dependencies, and the
FlutterEngine construction all work inside `:pluginhost` for this real
app, not just droidtop's own trivial sample. Two install-time bugs found
and fixed on the rig, both in plugin-core (not droidtop itself):
1. Manifest `origin` must be `"droidtop"` -- the only origin whose public
   key is pinned on-device, matching the key `sign.sh` actually signs
   with (droidtop-dev's own `droidtop-origin-private.pem`). This repo's
   own account name (`bi0shacker001`) is not a droidtop plugin origin.
2. The plugin id must be namespaced `<origin>.<name>` --
   `droidtop.romgi-<line>`, not `bi0shacker001.romgi-<line>`.

**Not yet exercised on the rig:** the actual `search`/`download` calls --
droidtop's Settings UI only builds a generic "Call ... status tile" debug
row for `status_tile`-capability plugins; there is no equivalent generic
trigger for `acquire_content` yet (droidtop-side work, not a bug in this
wrapper). `romgi (main)` loading and staying "Running" is the strongest
signal available without that UI existing yet -- a full search test needs
either a debug invoke surface added to droidtop's Settings screen (a
generic, non-romgi-specific addition) or the real future UI (search
input, results list) PLUGIN-PLAN.md's own capability section already
anticipates.
