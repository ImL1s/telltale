#!/usr/bin/env bash
# Build an unsigned macOS .app and wrap it in a drag-install DMG.
#
# Notarization / Developer ID signing are intentionally out of scope here —
# they need Apple secrets. The DMG is fine for local/QA distribution; Gatekeeper
# will warn until the app is signed+notarized.
#
# Usage (from app/):
#   tool/packaging/macos_dmg.sh
#   tool/packaging/macos_dmg.sh --skip-build   # reuse existing Release .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}"
OUT_DIR="${PACKAGING_OUT:-$ROOT/build/packaging}"
APP_NAME="Telltale"
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

cd "$ROOT"
mkdir -p "$OUT_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$FLUTTER" pub get
  "$FLUTTER" build macos --release
fi

APP_PATH="$ROOT/build/macos/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Refusing: missing $APP_PATH — run without --skip-build" >&2
  exit 1
fi

VERSION="$(
  python3 - <<'PY'
import re, pathlib
text = pathlib.Path("pubspec.yaml").read_text(encoding="utf-8")
m = re.search(r"^version:\s*([^\s+]+)", text, re.M)
print(m.group(1) if m else "0.0.0")
PY
)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/telltale-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT_DIR/${APP_NAME}-${VERSION}-macos-unsigned.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

echo "macOS unsigned DMG: $DMG"
echo "NOTE: not notarized. Users must right-click → Open, or sign with"
echo "      Developer ID + notarytool before public distribution."
