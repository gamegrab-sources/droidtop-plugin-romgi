#!/usr/bin/env bash
# Signs and packages an already-built plugin bundle (build.sh output:
# manifest.json + payload/{lib,flutter_assets}) into
# <plugin id>.droidplugin.tar.xz.
#
# This plugin is private and not part of the official droidtop trust
# ring: it signs with its own independent P-256 key (origin
# "bi0shacker001"), generated separately and never derived from
# droidtop's master/root key. The key lives as this repo's own
# PRIVATE_PLUGIN_SIGNING_KEY GitHub Actions secret, and CI signs the
# bundle itself (writes the value to a temp PEM file for the duration
# of the job). It can also be run locally with PRIVATE_PLUGIN_SIGNING_KEY
# pointed at a PEM file path on disk.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${PRIVATE_PLUGIN_SIGNING_KEY:?set to a PEM file path for this repo own independent private key}"
: "${BUNDLE_DIR:=droidtop_plugin/build}"

test -f "$BUNDLE_DIR/manifest.json" || { echo "missing $BUNDLE_DIR/manifest.json -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/lib" || { echo "missing $BUNDLE_DIR/payload/lib -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/flutter_assets" || { echo "missing $BUNDLE_DIR/payload/flutter_assets -- run droidtop_plugin/build.sh first" >&2; exit 1; }

PLUGIN_ID="$(python3 -c "import json; print(json.load(open('$BUNDLE_DIR/manifest.json'))['id'])")"

openssl dgst -sha256 -sign "$PRIVATE_PLUGIN_SIGNING_KEY" "$BUNDLE_DIR/manifest.json" | base64 -w0 > "$BUNDLE_DIR/manifest.sig"

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
