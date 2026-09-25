# romgi as a droidtop plugin

Private plan. Upstream: https://github.com/caprado/romgi (MIT). Owner's
installed build: `com.bi0shacker001.romgi` (package renamed from upstream's
`com.caprado.romgi`; `MainActivity` is unchanged, see
`/root/coordination/romgi-integration.md`).

## What it would contribute

romgi is a search/download ROM manager: dio for HTTP, sqflite for a local
scraped index (`db/romdb.db.gz`), and `lib/services/{debrid,metadata,torrent}`
for its sources. To droidtop that maps to exactly one surface: an
`acquire_content` action inside a system's own settings screen ("Download
games"), which searches romgi for that system and saves straight into the
system's real destination folder. Nothing else in droidtop's UI needs romgi —
no status tile, no library entries (romgi's results become droidtop library
entries only once the files land in a scanned folder, same as any other ROM).

## Reuse as a native bundle: not practical here

droidtop's plugin form (SPEC §12a) is a signed subplugin bundle loaded into
*enginehost's* process — the same mechanism as engine bundles, native
code plus manifest, no separate APK, no Python. romgi is a Flutter app: its
UI, its state (Riverpod), and its service layer all run inside the Flutter
engine and a Dart AOT snapshot, not as JVM/Kotlin classes or a plain `.so`.
There's no clean way to extract `lib/services/*` into a subplugin without
rewriting them in Kotlin/native code against enginehost's contract — which
would mean reimplementing a ROM downloader a second time, exactly the
duplication `docs/SPEC.md` §12a's closing paragraph already rejects for the
scraper case ("driving the real app through a real intent is the honest
shape").

So: **no subplugin for romgi.** The existing JSON-half plan in
`romgi-integration.md` is the whole mechanism — an intent filter on
`MainActivity`, extras (`system`, `systemName`, `dest`, `query`), and Dart-side
handling of those extras to pre-select the platform and save location. That
work is romgi-side Dart/Flutter, tracked as commits on this repo's `main`
once picked up (not yet started — flagged as "someone who can run the app"
work in the integration note).

## Root

Not needed. romgi already declares `MANAGE_EXTERNAL_STORAGE` and writes
under its own UID to `/storage/.../Roms/<system>` with no root and no URI
handover. Root offers nothing new here.

## What it needs from droidtop's plugin API

Nothing from the *plugin* (subplugin) surface — romgi never becomes a
subplugin. From the JSON half, which already exists (SPEC §12), it needs
only what `romgi-integration.md` already specifies: the `acquire_content`
capability with `{system.id}`, `{system.name}`, `{system.folder}`
placeholders, already implemented on droidtop's side. The remaining work is
entirely in this fork: the intent filter and the Dart-side extras handling.
