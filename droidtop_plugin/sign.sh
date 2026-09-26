#!/usr/bin/env bash
# Signs and packages an already-built plugin bundle (build.sh output:
# manifest.json + payload/{lib,flutter_assets}) into
# <plugin id>.droidplugin.tar.xz. Pattern copied from droidtop's own
# samples/plugin-sample-flutter-statustile/sign.sh.
#
# The ONLY script in this repo that touches the plugin origin private
# key. Run this on droidtop-dev only, where
# /root/coordination/keys/droidtop-plugins/ lives; the key is never
# committed here and never given to CI.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${PLUGIN_SIGNING_KEY:?set to the droidtop plugin origin EC private key PEM}"
: "${BUNDLE_DIR:=droidtop_plugin/build}"

test -f "$BUNDLE_DIR/manifest.json" || { echo "missing $BUNDLE_DIR/manifest.json -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/lib" || { echo "missing $BUNDLE_DIR/payload/lib -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/flutter_assets" || { echo "missing $BUNDLE_DIR/payload/flutter_assets -- run droidtop_plugin/build.sh first" >&2; exit 1; }

PLUGIN_ID="$(python3 -c "import json; print(json.load(open('$BUNDLE_DIR/manifest.json'))['id'])")"

openssl dgst -sha256 -sign "$PLUGIN_SIGNING_KEY" "$BUNDLE_DIR/manifest.json" | base64 -w0 > "$BUNDLE_DIR/manifest.sig"

# GNU tar's repeated -C is CUMULATIVE (relative to wherever the previous
# -C left it, not this script's own cwd) -- absolute paths sidestep it,
# same fix droidtop's own sample sign.sh needed for this exact pattern.
BUNDLE_ABS="$(cd "$BUNDLE_DIR" && pwd)"
OUT="${PLUGIN_ID}.droidplugin.tar.xz"
tar --sort=name -cf - \
  -C "$BUNDLE_ABS" manifest.json manifest.sig \
  -C "$BUNDLE_ABS/payload" lib flutter_assets \
  | xz -9e > "$OUT"

echo "Signed $OUT"
sha256sum "$OUT"
