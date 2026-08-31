#!/usr/bin/env bash
# Package a Windows desktop Release build as a portable zip.
#
# MSIX / store signing needs a certificate and is stubbed in README.md — this
# script only produces an unsigned runnable tree zip suitable for CI artifacts
# and sideload smoke.
#
# Run on Windows (Git Bash / MSYS) or document the same steps in CI:
#   tool/packaging/windows_zip.sh
#   tool/packaging/windows_zip.sh --skip-build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
OUT_DIR="${PACKAGING_OUT:-$ROOT/build/packaging}"
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done

cd "$ROOT"
mkdir -p "$OUT_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$FLUTTER" pub get
  "$FLUTTER" build windows --release
fi

# Flutter 3.x places the runner under x64 (or arm64 on ARM hosts).
RUNNER=""
for candidate in \
  "$ROOT/build/windows/x64/runner/Release" \
  "$ROOT/build/windows/arm64/runner/Release"
do
  if [[ -f "$candidate/telltale.exe" || -f "$candidate/Telltale.exe" ]]; then
    RUNNER="$candidate"
    break
  fi
done
if [[ -z "$RUNNER" ]]; then
  echo "Refusing: no Release runner under build/windows/*/runner/Release" >&2
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
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/telltale-winzip.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Telltale"
cp -R "$RUNNER"/. "$STAGE/Telltale/"

ZIP="$OUT_DIR/Telltale-${VERSION}-windows-unsigned.zip"
rm -f "$ZIP"
(
  cd "$STAGE"
  if command -v zip >/dev/null 2>&1; then
    zip -qr "$ZIP" Telltale
  else
    python3 - <<PY
import pathlib, zipfile
root = pathlib.Path("Telltale")
out = pathlib.Path(r"""$ZIP""")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for path in root.rglob("*"):
        if path.is_file():
            zf.write(path, path.as_posix())
print(out)
PY
  fi
)

echo "Windows unsigned zip: $ZIP"
echo "NOTE: not an MSIX. See tool/packaging/README.md for the MSIX stub."
