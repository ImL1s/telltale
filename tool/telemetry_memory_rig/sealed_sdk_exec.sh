#!/bin/zsh -f
set -euo pipefail

die() { print -u2 -- "sealed SDK exec: $*"; exit 64; }

(( $# >= 2 )) || die "usage: sealed_sdk_exec.sh <flutter-root> <flutter|dart> [args...]"
FLUTTER_ROOT=${1:A}
MODE=$2
shift 2

CACHED_DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
FLUTTER_SNAPSHOT="$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
FLUTTER_PACKAGES="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json"

[[ -x "$CACHED_DART" ]] || die "cached Dart is not executable: $CACHED_DART"

case "$MODE" in
  flutter)
    [[ -f "$FLUTTER_SNAPSHOT" && ! -L "$FLUTTER_SNAPSHOT" ]] \
      || die "Flutter tools snapshot is missing or unsafe: $FLUTTER_SNAPSHOT"
    [[ -f "$FLUTTER_PACKAGES" && ! -L "$FLUTTER_PACKAGES" ]] \
      || die "Flutter tools package config is missing or unsafe: $FLUTTER_PACKAGES"
    export FLUTTER_ROOT
    unset FLUTTER_TOOL_ARGS
    exec "$CACHED_DART" \
      --packages="$FLUTTER_PACKAGES" \
      "$FLUTTER_SNAPSHOT" "$@"
    ;;
  dart)
    exec "$CACHED_DART" "$@"
    ;;
  *)
    die "unsupported mode: $MODE"
    ;;
esac
