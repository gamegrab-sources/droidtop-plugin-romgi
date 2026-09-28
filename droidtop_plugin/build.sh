#!/usr/bin/env bash
# Builds this branch's romgi flutter_embed plugin bundle (unsigned).
# Same split as droidtop's own samples/plugin-sample-flutter-statustile:
# this script never touches the plugin origin's private key and is safe
# to run in CI; only droidtop-dev, which holds
# /root/coordination/keys/droidtop-plugins/, ever runs sign.sh.
#
# Unlike that sample, this is NOT a throwaway scaffolded project: it
# builds THIS repo's own real pubspec.yaml/android project (romgi's own
# dependencies, already vetted and working), just pointed at a different
# Dart entrypoint via --target. That is the whole plugin-core patch on
# the Dart side: one new file, lib/droidtop_plugin_main.dart, importing
# romgi's own services/models unmodified, plus one additive factory on
# NotificationService (see that file's own comment) -- nothing else in
# this repo's real app code is touched by this build.
#
# The plugin id (and its manifest, and this build's --dart-define, which
# must match) is derived from the CURRENT BRANCH, so plugin-core's own
# commit is the only Dart/build source shared across every plugin/<line>
# branch -- no per-line source edits, no per-line manifest to hand-keep
# in sync.
#
# Prerequisites: same pinned Flutter version as droidtop's own
# flutter_embed samples (see plugin-host/src/main/assets/flutter-runtimes.json
# in the droidtop repo) -- a build with a different Flutter/engine version
# produces a libapp.so PluginRuntimeService.loadFlutterPlugin refuses at
# load (runtimeVersion mismatch), which is deliberate, not a bug.

set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME_VERSION="af7e796e161ae0bb1ff0758c71a7105418bd9ded"

command -v flutter >/dev/null || { echo "flutter not on PATH -- see this script's own header for the pinned version" >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LINE="${BRANCH#plugin/}"
if [ "$LINE" = "$BRANCH" ] || [ -z "$LINE" ]; then
  # Not on a plugin/<line> branch (e.g. testing straight from plugin-core) --
  # a distinct, clearly-not-real id so this never gets confused with an
  # actual installable line's bundle.
  LINE="dev"
fi
# The manifest's origin is "bi0shacker001" -- this repo's own
# independent signing key, not droidtop's master/root key -- and
# PluginBundleInstaller requires an id namespaced as "<origin>.<name>".
PLUGIN_ID="bi0shacker001.romgi-${LINE}"

echo "Building line '$LINE' as plugin id '$PLUGIN_ID'"

rm -rf droidtop_plugin/build
mkdir -p droidtop_plugin/build/payload

flutter pub get
flutter build apk --release \
  --target=lib/droidtop_plugin_main.dart \
  --target-platform android-arm64,android-x64 \
  --dart-define=DROIDTOP_PLUGIN_ID="$PLUGIN_ID"

APK=build/app/outputs/flutter-apk/app-release.apk
test -f "$APK" || { echo "flutter build apk didn't produce $APK" >&2; exit 1; }

mkdir -p droidtop_plugin/build/payload/lib/arm64-v8a droidtop_plugin/build/payload/lib/x86_64
unzip -p "$APK" lib/arm64-v8a/libapp.so > droidtop_plugin/build/payload/lib/arm64-v8a/libapp.so
unzip -p "$APK" lib/x86_64/libapp.so > droidtop_plugin/build/payload/lib/x86_64/libapp.so

# flutter_assets lives at "assets/flutter_assets/**" inside the APK; the
# plugin payload wants it at its own top-level "flutter_assets/**" (what
# FlutterDroidtopPlugin.loadAssetsIntoEngine reads from installDir) --
# same repack droidtop's own sample build.sh does.
EXTRACT_DIR="$(mktemp -d)"
unzip -q "$APK" 'assets/flutter_assets/*' -d "$EXTRACT_DIR"
cp -r "$EXTRACT_DIR/assets/flutter_assets" droidtop_plugin/build/payload/flutter_assets
rm -rf "$EXTRACT_DIR"

python3 - "$RUNTIME_VERSION" "$PLUGIN_ID" "$LINE" <<'PY'
import hashlib, json, os, sys

runtime_version, plugin_id, line = sys.argv[1:4]
payload_root = "droidtop_plugin/build/payload"
payload = []
for dirpath, _dirs, files in os.walk(payload_root):
    for name in sorted(files):
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, payload_root).replace(os.sep, "/")
        sha = hashlib.sha256(open(full, "rb").read()).hexdigest()
        payload.append({"path": rel, "sha256": sha})
payload.sort(key=lambda e: e["path"])

manifest = json.load(open("droidtop_plugin/manifest.template.json"))
manifest["id"] = plugin_id
manifest["label"] = f"romgi ({line})"
manifest["runtimeVersion"] = runtime_version
manifest["payload"] = payload
json.dump(manifest, open("droidtop_plugin/build/manifest.json", "w"), indent=2, sort_keys=True)
print(f"payload: {len(payload)} files, id={plugin_id}")
PY

echo "Built droidtop_plugin/build/payload/{lib,flutter_assets} and droidtop_plugin/build/manifest.json (unsigned)"

if [ -n "${PRIVATE_PLUGIN_SIGNING_KEY:-}" ]; then
  PRIVATE_PLUGIN_SIGNING_KEY="$PRIVATE_PLUGIN_SIGNING_KEY" ./droidtop_plugin/sign.sh
else
  echo "PRIVATE_PLUGIN_SIGNING_KEY not set -- stopping here, unsigned."
  echo "Run droidtop_plugin/sign.sh with PRIVATE_PLUGIN_SIGNING_KEY set to a PEM file path to produce ${PLUGIN_ID}.droidplugin.tar.xz."
fi
