#!/usr/bin/env bash
# Start Ircama ELM327-emulator on 127.0.0.1:35000 and run the Wi‑Fi oracle suite.
#
# macOS note: without `-d` (daemon), backgrounding this CLI under a closed stdin
# exits immediately after an empty batch file. Linux CI keeps the non-daemon
# form alive in Actions; local macOS evidence uses daemon mode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}"
VENV="${ELM_VENV:-/tmp/elmvenv-torque-wifi}"
PORT="${ELM_ORACLE_PORT:-35000}"

cd "$ROOT"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q setuptools==80.10.2 wheel==0.45.1
  env -u GITHUB_RUN_NUMBER "$VENV/bin/pip" install -q --no-build-isolation \
    --no-cache-dir ELM327-emulator==3.0.5
  "$VENV/bin/pip" check
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Refusing: something already listens on :$PORT" >&2
  exit 1
fi

ELM_PID_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telltale-elm.XXXXXX")"
chmod 700 "$ELM_PID_DIR"
cleanup() {
  if [[ -n "${emulator_pid:-}" ]]; then
    kill "$emulator_pid" 2>/dev/null || true
    wait "$emulator_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$VENV/bin/python" tool/ble_test_rig/emulator_entrypoint.py \
  --pid-directory "$ELM_PID_DIR" \
  -n "$PORT" -s car -d \
  -b "$ELM_PID_DIR/batch.log" >"$ELM_PID_DIR/elm.log" 2>&1 &
emulator_pid=$!

for _ in $(seq 1 50); do
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1

"$FLUTTER" test test/emulator_integration_test.dart \
  --dart-define=ELM_ORACLE_REQUIRED=true \
  --dart-define=ELM_ORACLE_PORT="$PORT"

echo "desktop Wi-Fi oracle evidence: PASS (Ircama on 127.0.0.1:$PORT)"
echo "state dir: $ELM_PID_DIR"
