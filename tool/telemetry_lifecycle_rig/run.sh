#!/bin/zsh
set -euo pipefail
umask 077

die() { print -u2 -- "telemetry lifecycle rig: $*"; exit 1; }

[[ $# == 1 ]] || die "usage: tool/telemetry_lifecycle_rig/run.sh <adb-serial>"
SERIAL=$1
HERE=${0:a:h}
APP_ROOT=${HERE:h:h}
FLUTTER=${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}
ADB=${ADB:-adb}
PACKAGE=com.cbstudio.telltale.rig
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE=${TELEMETRY_RIG_EVIDENCE_DIR:-$APP_ROOT/.omx/logs/telemetry-lifecycle-rig-$STAMP}
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"

[[ -x "$FLUTTER" ]] || die "pinned Flutter not executable: $FLUTTER"
command -v "$ADB" >/dev/null || die "adb is unavailable"
device_state=$($ADB -s "$SERIAL" get-state 2>/dev/null || true)
[[ "$device_state" == device ]] || die "device $SERIAL is not authorized/online"

typeset -a BASE
BASE=("$FLUTTER" test integration_test/telemetry_lifecycle_rig_test.dart \
  -d "$SERIAL" --flavor rig --dart-define=TELLTALE_TEST_RIG=true)

wait_for_marker() {
  local file=$1 marker=$2 pid=$3 i
  for i in {1..240}; do
    grep -Fq "$marker" "$file" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

cd "$APP_ROOT"
print -r -- "serial=$SERIAL" > "$EVIDENCE/device.txt"
$ADB -s "$SERIAL" shell getprop ro.product.model >> "$EVIDENCE/device.txt"
$ADB -s "$SERIAL" shell getprop ro.build.version.release >> "$EVIDENCE/device.txt"
$ADB -s "$SERIAL" shell getprop ro.build.version.sdk >> "$EVIDENCE/device.txt"

HOME_LOG="$EVIDENCE/home.log"
"${BASE[@]}" --dart-define=TELEMETRY_LIFECYCLE_PHASE=home >"$HOME_LOG" 2>&1 &
home_pid=$!
wait_for_marker "$HOME_LOG" TELLTALE_LIFECYCLE_READY_HOME "$home_pid" \
  || { kill "$home_pid" 2>/dev/null || true; die "Home target never became ready; see $HOME_LOG"; }
$ADB -s "$SERIAL" shell input keyevent KEYCODE_HOME
wait "$home_pid" || die "Home lifecycle target failed; see $HOME_LOG"
grep -Fq TELLTALE_LIFECYCLE_HOME_STORED "$HOME_LOG" \
  || die "Home target did not prove a finalized artifact"

SEED_LOG="$EVIDENCE/force-stop-seed.log"
"${BASE[@]}" --dart-define=TELEMETRY_LIFECYCLE_PHASE=force_stop_seed >"$SEED_LOG" 2>&1 &
seed_pid=$!
wait_for_marker "$SEED_LOG" TELLTALE_LIFECYCLE_READY_FORCE_STOP "$seed_pid" \
  || { kill "$seed_pid" 2>/dev/null || true; die "force-stop seed never became ready; see $SEED_LOG"; }
grep -Eq \
  'TELLTALE_LIFECYCLE_READY_FORCE_STOP session=[0-9a-f]{32} values=[1-9][0-9]* statuses=[0-9]+ gaps=[0-9]+' \
  "$SEED_LOG" \
  || { kill "$seed_pid" 2>/dev/null || true; die "force-stop seed marker was incomplete; see $SEED_LOG"; }
$ADB -s "$SERIAL" shell am force-stop "$PACKAGE"
set +e
wait "$seed_pid"
seed_rc=$?
set -e
(( seed_rc != 0 )) || die "force-stopped seed unexpectedly exited green"

RECOVERY_LOG="$EVIDENCE/recovery.log"
"${BASE[@]}" --dart-define=TELEMETRY_LIFECYCLE_PHASE=recover >"$RECOVERY_LOG" 2>&1 \
  || die "fresh-process recovery failed; see $RECOVERY_LOG"
grep -Fq TELLTALE_LIFECYCLE_RECOVERED "$RECOVERY_LOG" \
  || die "fresh process did not emit recovery proof"

python3 "$HERE/verify_evidence.py" \
  --home "$HOME_LOG" --seed "$SEED_LOG" --recovery "$RECOVERY_LOG"
print -r -- "telemetry lifecycle rig: PASS ($EVIDENCE)"
