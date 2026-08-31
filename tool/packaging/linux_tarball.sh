#!/usr/bin/env bash
# Package a Linux desktop Release bundle as a relocatable tarball.
#
# AppImage / Flatpak need extra tooling and (for Flathub) maintainer review —
# stubs live in README.md. This script is the free, no-secrets baseline.
#
# Usage (from app/, on Linux with GTK deps):
#   tool/packaging/linux_tarball.sh
#   tool/packaging/linux_tarball.sh --skip-build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
OUT_DIR="${PACKAGING_OUT:-$ROOT/build/packaging}"
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
  "$FLUTTER" build linux --release
fi

# default-flavor: field → …/field/release/bundle; keep unflavored as fallback.
BUNDLE=""
for candidate in \
  "$ROOT/build/linux/x64/field/release/bundle" \
  "$ROOT/build/linux/arm64/field/release/bundle" \
  "$ROOT/build/linux/x64/release/bundle" \
  "$ROOT/build/linux/arm64/release/bundle"
do
  if [[ -d "$candidate" ]]; then
    BUNDLE="$candidate"
    break
  fi
done
if [[ -z "$BUNDLE" ]]; then
  echo "Refusing: missing Linux release bundle under build/linux/*/[field/]release/bundle" >&2
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
# …/<arch>/[field/]release/bundle → arch is two or three levels above bundle.
_release_dir="$(dirname "$BUNDLE")"
_flavor_or_arch="$(dirname "$_release_dir")"
if [[ "$(basename "$_flavor_or_arch")" == "field" ]]; then
  ARCH="$(basename "$(dirname "$_flavor_or_arch")")"
else
  ARCH="$(basename "$_flavor_or_arch")"
fi
TAR="$OUT_DIR/Telltale-${VERSION}-linux-${ARCH}.tar.gz"
rm -f "$TAR"
tar -C "$(dirname "$BUNDLE")" -czf "$TAR" "$(basename "$BUNDLE")"
# Rename inner folder notionally: keep Flutter's `bundle/` name for honesty.
echo "Linux tarball: $TAR"
echo "Run: tar -xzf \"$TAR\" && ./bundle/telltale"
echo "NOTE: AppImage/Flatpak stubs are in tool/packaging/README.md — not built here."
