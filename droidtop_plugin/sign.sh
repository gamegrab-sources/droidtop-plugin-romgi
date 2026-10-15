#!/usr/bin/env bash
# Signs and packages an already-built plugin bundle (build.sh output:
# manifest.json + payload/{lib,dex,flutter_assets}) into
# <plugin id>.droidplugin.tar.xz.
#
# The origin is "romgi": this repository's key has a leaf certificate issued by
# Droidtop Core (droidtop-plugin-key.json carries the same leaf). The bundle
# carries manifest.jws, a detached ES256 JWS over the exact manifest.json bytes
# with that leaf in x5c (droidtop docs/SPEC.md 12a). CI writes the secrets
# PLUGIN_SIGNING_KEY and PLUGIN_SIGNING_CERT to private temporary files and
# passes their paths here.

set -euo pipefail
JWS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."

: "${PLUGIN_SIGNING_KEY:?set to the path of this repository's private key (PEM)}"
: "${PLUGIN_SIGNING_CERT:?set to the path of this key's leaf certificate (PEM) issued by Droidtop Core}"
: "${BUNDLE_DIR:=droidtop_plugin/build}"

test -f "$BUNDLE_DIR/manifest.json" || { echo "missing $BUNDLE_DIR/manifest.json -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/lib" || { echo "missing $BUNDLE_DIR/payload/lib -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/dex" || { echo "missing $BUNDLE_DIR/payload/dex -- run droidtop_plugin/build.sh first" >&2; exit 1; }
test -d "$BUNDLE_DIR/payload/flutter_assets" || { echo "missing $BUNDLE_DIR/payload/flutter_assets -- run droidtop_plugin/build.sh first" >&2; exit 1; }

PLUGIN_ID="$(python3 -c "import json; print(json.load(open('$BUNDLE_DIR/manifest.json'))['id'])")"

python3 -c 'import cryptography' 2>/dev/null || python3 -m pip install --quiet --user --break-system-packages 'cryptography>=42'
python3 "$JWS_DIR/sign_jws.py" droidtop-plugin+jws "$BUNDLE_DIR/manifest.json" "$PLUGIN_SIGNING_KEY" "$PLUGIN_SIGNING_CERT" > "$BUNDLE_DIR/manifest.jws"

# GNU tar's repeated -C is CUMULATIVE (relative to wherever the previous
# -C left it, not this script's own cwd) -- absolute paths sidestep it,
# same fix droidtop's own sample sign.sh needed for this exact pattern.
BUNDLE_ABS="$(cd "$BUNDLE_DIR" && pwd)"
OUT="${PLUGIN_ID}.droidplugin.tar.xz"
tar --sort=name -cf - \
  -C "$BUNDLE_ABS" manifest.json manifest.jws \
  -C "$BUNDLE_ABS/payload" lib dex flutter_assets \
  | xz -9e > "$OUT"

echo "Signed $OUT"
sha256sum "$OUT"
