#!/bin/zsh
# Local-only, real-CoreBluetooth BLE peripheral in front of an ELM emulator.
set -euo pipefail
umask 077
# LaunchServices injects these for BleHost. The controller also calls the
# system Python for JSONL events, which must not inherit the app bundle's
# virtual-environment paths when the bridge invokes --expire.
unset PYTHONHOME PYTHONPATH
export PIP_DISABLE_PIP_VERSION_CHECK=1

die() { print -u2 -- "ble rig: $*"; return 1; }
zmodload zsh/system || { die "zsh/system is required for advisory locks"; exit 1; }

require_owned_directory() {
  local target=$1 owner
  [[ -d "$target" && ! -L "$target" ]] \
    || { die "unsafe directory: $target"; return 1; }
  owner=$(stat -f '%u' "$target" 2>/dev/null) \
    || { die "could not inspect directory: $target"; return 1; }
  [[ "$owner" == "$EUID" ]] \
    || { die "directory is not owned by uid $EUID: $target"; return 1; }
}

require_owned_regular_file() {
  local target=$1 owner
  [[ -f "$target" && ! -L "$target" ]] \
    || { die "unsafe executable file: $target"; return 1; }
  owner=$(stat -f '%u' "$target" 2>/dev/null) \
    || { die "could not inspect executable file: $target"; return 1; }
  [[ "$owner" == "$EUID" ]] \
    || { die "executable file is not owned by uid $EUID: $target"; return 1; }
}

require_private_temp_root() {
  local target=$1 mode
  require_owned_directory "$target" || return 1
  mode=$(stat -f '%Lp' "$target" 2>/dev/null) \
    || { die "could not inspect temporary directory mode: $target"; return 1; }
  (( (8#$mode & 8#077) == 0 )) \
    || { die "temporary directory is accessible by other users: $target"; return 1; }
}

HERE=${0:a:h}
HOST_ROOT=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null) \
  || { die "could not locate the per-user macOS temporary directory"; exit 1; }
HOST_ROOT=${HOST_ROOT%/}
require_private_temp_root "$HOST_ROOT" || exit 1
if [[ -n "${TMPDIR:-}" ]]; then
  TMP_ROOT=$TMPDIR
else
  TMP_ROOT=$HOST_ROOT
fi
TMP_ROOT=${TMP_ROOT%/}
require_private_temp_root "$TMP_ROOT" || exit 1
# Keep the host bundle's signed contents stable when a caller selects a custom
# controller TMPDIR. CoreBluetooth TCC grants are code-requirement specific;
# embedding a different venv path into Info.plist creates a new ad-hoc identity
# and prompts again instead of advertising. Run state remains under TMP_ROOT.
VENV=$HOST_ROOT/telltale-ble-rig-venv
APP=$HOST_ROOT/BleHost.app
STATE=$TMP_ROOT/telltale-ble-rig
RUNTIME="$STATE/runtime"
IRCAMA_PID_LOCK="$STATE/ircama.pid"
PORT=35000
BRIDGE_LOG=/tmp/ble_bridge.log
CLIENT_LOG=/tmp/ble_client.log
RIG_LOG="$STATE/events.jsonl"
# VENV, APP, and TCP port 35000 are host-global resources. Keep their controller
# mutex under the same canonical owner-private root, not the caller-selected
# state root, so distinct private TMPDIR values cannot enter setup concurrently.
CONTROLLER_LOCK="$HOST_ROOT/telltale-ble-rig.controller.lock"
CONTROLLER_LOCK_FD=0
if [[ -e "$STATE" ]]; then
  require_owned_directory "$STATE" || exit 1
else
  mkdir -m 700 "$STATE"
fi
chmod 700 "$STATE"
find "$STATE" -maxdepth 1 -type f -exec chmod 600 {} +

release_controller_lock() {
  # zsh inherits EXIT traps into command-substitution subshells while keeping
  # `$$` unchanged. Without this guard, the first `$(...)` in a start removed
  # its parent's live lock and allowed a concurrent controller into the state.
  (( ${ZSH_SUBSHELL:-0} == 0 )) || return 0
  [[ "${CONTROLLER_LOCK_HELD:-0}" == 1 ]] || return 0
  zsystem flock -u "$CONTROLLER_LOCK_FD" || true
  CONTROLLER_LOCK_FD=0
  CONTROLLER_LOCK_HELD=0
}

candidate_process_ids() {
  local name=$1 candidate pattern
  local -a candidates
  candidates=()
  if [[ "$name" == emulator ]]; then
    candidate=$(cat "$IRCAMA_PID_LOCK" 2>/dev/null || true)
    [[ "$candidate" == <-> ]] && candidates+=("$candidate")
    pattern="$RUNTIME/emulator_entrypoint.py"
  else
    pattern="$RUNTIME/bridge.py"
  fi
  for candidate in $(pgrep -f "$pattern" 2>/dev/null || true); do
    (( ${candidates[(Ie)$candidate]} )) || candidates+=("$candidate")
  done
  print -l -- "${candidates[@]}"
}

list_owned_processes() {
  local name=$1 token=$2 candidate fingerprint
  for candidate in $(candidate_process_ids "$name"); do
    fingerprint=$(process_fingerprint "$name" "$candidate" "$token" 2>/dev/null) \
      || continue
    print -- "$candidate $fingerprint"
  done
}

discover_owned_processes() {
  local name=$1 candidate identity
  for candidate in $(candidate_process_ids "$name"); do
    identity=$(/usr/bin/python3 "$HERE/process_identity.py" \
      --discover "$name" "$candidate" "$RUNTIME" "$VENV" "$APP" "$STATE" "$PORT" \
      2>/dev/null) || continue
    print -- "$candidate $identity"
  done
}

recover_owned_pid_file() {
  local name=$1 token=$2 pid_file="$STATE/$1.pid" matches=''
  local -a candidates
  owned_pid "$name" "$token" >/dev/null 2>&1 && return 0
  matches=$(list_owned_processes "$name" "$token") || return 1
  [[ -n "$matches" ]] || return 1
  candidates=("${(@f)matches}")
  (( ${#candidates[@]} == 1 )) || return 1
  print -- "${candidates[1]%% *} $token ${candidates[1]#* }" > "$pid_file"
  owned_pid "$name" "$token" >/dev/null 2>&1
}

cleanup_partial_start() {
  local name attempt recovered matches owner cleanup_failed=0
  (( ${ZSH_SUBSHELL:-0} == 0 )) || return 0
  [[ "${START_CLEANUP_ARMED:-0}" == 1 ]] || return 0
  START_CLEANUP_ARMED=0
  for name in bridge emulator; do
    [[ "$name" == bridge && "${START_BRIDGE_MAY_EXIST:-0}" != 1 ]] \
      && continue
    [[ "$name" == emulator && "${START_EMULATOR_MAY_EXIST:-0}" != 1 ]] \
      && continue
    # LaunchServices and python-daemon both return before the durable child has
    # necessarily published its PID. After an interrupt, briefly recover by
    # exact path + ownership token so a just-spawned process cannot escape.
    recovered=0
    for attempt in {1..50}; do
      if recover_owned_pid_file "$name" "$START_TOKEN"; then
        recovered=1
        break
      fi
      sleep 0.1
    done
    if (( recovered )); then
      stop_one "$name" "$START_TOKEN" || true
    fi
    matches=$(list_owned_processes "$name" "$START_TOKEN" || true)
    [[ -z "$matches" && ! -f "$STATE/$name.pid" ]] || cleanup_failed=1
  done
  owner=$(port_owner)
  [[ -z "$owner" ]] || cleanup_failed=1
  if (( cleanup_failed )); then
    rig_event start_cleanup result cleanup_incomplete port_owner "${owner:-none}" \
      || true
    return 1
  fi
  rig_event start_cleanup result owned_processes_absent || true
}

on_exit() {
  local rc=$? cleanup_rc=0
  trap - EXIT ZERR INT TERM HUP
  set +e
  cleanup_partial_start || cleanup_rc=$?
  release_controller_lock
  (( rc != 0 || cleanup_rc == 0 )) || rc=$cleanup_rc
  exit "$rc"
}

on_error() {
  local rc=$?
  # zsh's ZERR trap continues after a returning handler. Exit explicitly after
  # cleanup so a failed ownership/readiness check cannot fall through to a
  # misleading success record.
  trap - ZERR EXIT INT TERM HUP
  set +e
  cleanup_partial_start || true
  release_controller_lock
  exit "$rc"
}

on_signal() {
  local rc=$1
  trap - INT TERM HUP
  exit "$rc"
}

acquire_controller_lock() {
  [[ ! -L "$CONTROLLER_LOCK" ]] || die "unsafe controller lock symlink"
  touch "$CONTROLLER_LOCK"
  chmod 600 "$CONTROLLER_LOCK"
  require_owned_regular_file "$CONTROLLER_LOCK" || return 1
  if ! zsystem flock -t 60 -f CONTROLLER_LOCK_FD "$CONTROLLER_LOCK"; then
    CONTROLLER_LOCK_FD=0
    die "controller lock stayed busy for 60 seconds"
  fi
  CONTROLLER_LOCK_HELD=1
}

rig_event() {
  local event=$1
  shift
  /usr/bin/python3 - "$RIG_LOG" "$event" "$@" <<'PY'
import json, os, sys, time
path, event, *pairs = sys.argv[1:]
if len(pairs) % 2:
    raise SystemExit("rig_event requires key/value pairs")
record = {"event": event, "time_unix_ms": time.time_ns() // 1_000_000}
record.update(zip(pairs[::2], pairs[1::2]))
flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags, 0o600)
os.fchmod(descriptor, 0o600)
with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

process_fingerprint() {
  local name=$1 pid=$2 token=$3 expected=${4:-}
  local -a args
  [[ "$pid" == <-> ]] || return 1
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args=(
    "$HERE/process_identity.py"
    "$name"
    "$pid"
    "$token"
    "$RUNTIME"
    "$VENV"
    "$APP"
    "$STATE"
    "$PORT"
  )
  [[ -z "$expected" ]] || args+=("$expected")
  /usr/bin/python3 "${args[@]}"
}

matches_owned_process() {
  process_fingerprint "$@" >/dev/null 2>&1
}

owned_pid() {
  local name=$1 expected_token=${2:-} pid_file="$STATE/$1.pid"
  local pid token fingerprint
  [[ -f "$pid_file" ]] || return 1
  read -r pid token fingerprint < "$pid_file" || return 1
  [[ -z "$expected_token" || "$token" == "$expected_token" ]] || return 1
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
  matches_owned_process "$name" "$pid" "$token" "$fingerprint" || return 1
  print -- "$pid"
}

port_owner() {
  lsof -nP -t -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

listener_endpoint() {
  local pid=$1
  lsof -nP -a -p "$pid" -iTCP:$PORT -sTCP:LISTEN -Fn 2>/dev/null \
    | sed -n 's/^n//p' \
    | head -n 1
}

verify_bridge_health() {
  local expected_pid=$1
  [[ -f "$BRIDGE_LOG" && ! -L "$BRIDGE_LOG" ]] || return 1
  /usr/bin/python3 - "$BRIDGE_LOG" "$expected_pid" <<'PY'
import json, sys, time

path, expected_pid_text = sys.argv[1:]
expected_pid = int(expected_pid_text)
latest = None
with open(path, encoding="utf-8") as stream:
    for line in stream:
        record = json.loads(line)
        if record.get("event") == "advertising_health":
            latest = record
if latest is None:
    raise SystemExit(1)
age_ms = time.time_ns() // 1_000_000 - int(latest.get("time_unix_ms", 0))
if (
    latest.get("pid") != expected_pid
    or latest.get("is_advertising") is not True
    or not -5_000 <= age_ms <= 3_000
):
    raise SystemExit(1)
PY
}

wait_owned_dead() {
  local name=$1 pid=$2 token=$3 fingerprint=$4
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || return 0
    # A different identity at the same PID means the owned process is gone.
    # Never signal the replacement.
    matches_owned_process "$name" "$pid" "$token" "$fingerprint" || return 0
    sleep 0.1
  done
  return 1
}

remove_ircama_pid_lock_after_stop() {
  local stopped_pid=$1 recorded
  [[ -e "$IRCAMA_PID_LOCK" || -L "$IRCAMA_PID_LOCK" ]] || return 0
  require_owned_regular_file "$IRCAMA_PID_LOCK" || return 2
  recorded=$(cat "$IRCAMA_PID_LOCK" 2>/dev/null) || return 2
  [[ "$recorded" == <-> && "$recorded" == "$stopped_pid" ]] || return 3
  # wait_owned_dead can return when the exact fingerprint disappears. Keep the
  # lock if that numeric PID is still live, including immediate PID reuse.
  kill -0 "$stopped_pid" 2>/dev/null && return 3
  rm -f "$IRCAMA_PID_LOCK"
}

prepare_ircama_pid_lock_for_start() {
  local recorded
  [[ -e "$IRCAMA_PID_LOCK" || -L "$IRCAMA_PID_LOCK" ]] || return 0
  require_owned_regular_file "$IRCAMA_PID_LOCK" || return 1
  recorded=$(cat "$IRCAMA_PID_LOCK" 2>/dev/null) || return 1
  [[ "$recorded" == <-> ]] \
    || { die "malformed stale Ircama PID lock: $IRCAMA_PID_LOCK"; return 1; }
  if kill -0 "$recorded" 2>/dev/null; then
    die "Ircama PID lock references live pid=$recorded"
    return 1
  fi
  rm -f "$IRCAMA_PID_LOCK"
}

_stop_one_locked() {
  local name=$1 expected_token=${2:-} pid_file="$STATE/$1.pid"
  local pid token fingerprint discovery_rc
  if [[ ! -f "$pid_file" ]]; then
    if [[ -z "$expected_token" ]]; then
      if _stop_discovered_owned_locked "$name"; then
        return 0
      else
        discovery_rc=$?
      fi
      (( discovery_rc == 4 )) && return 0
      return "$discovery_rc"
    fi
    return 3
  fi
  read -r pid token fingerprint < "$pid_file" || true
  if [[ -n "$expected_token" && "$token" != "$expected_token" ]]; then
    return 3
  fi
  # A bridge publishes pid+token before the controller can add its kernel
  # fingerprint. Recover that exact process after an interrupted start rather
  # than either abandoning it or trusting the bare PID.
  if [[ -n "$expected_token" \
      && "$token" =~ ^[0-9a-f]{32}$ \
      && ! "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
    recover_owned_pid_file "$name" "$token" || true
    read -r pid token fingerprint < "$pid_file" || true
  fi
  if owned_pid "$name" "$expected_token" >/dev/null; then
    # Close the check/use window as far as macOS permits without pidfds. In
    # particular, never signal a process after a concurrent run replaced the
    # PID file with a different ownership token.
    [[ "$(owned_pid "$name" "$expected_token" 2>/dev/null || true)" == "$pid" ]] \
      || return 3
    _stop_owned_identity_locked "$name" "$pid" "$token" "$fingerprint"
    return $?
  fi
  if [[ -z "$expected_token" ]]; then
    if _stop_discovered_owned_locked "$name" "$pid"; then
      # No controller can start concurrently while --stop holds the host-global
      # controller lock.
      # Remove a stale record only after every exact owned process is gone.
      rm -f "$pid_file"
      return 0
    else
      discovery_rc=$?
    fi
    if (( discovery_rc != 4 )); then
      return "$discovery_rc"
    fi
  fi
  if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
    print -u2 -- \
      "refusing to stop live unowned $name pid=$pid; inspect: ps eww -p $pid -o command="
    return 2
  fi
  print -u2 -- "ignored dead/malformed stale $pid_file"
  rm -f "$pid_file"
  [[ -z "$expected_token" ]] && return 0
  return 3
}

_stop_owned_identity_locked() {
  local name=$1 pid=$2 token=$3 fingerprint=$4
  local pid_file="$STATE/$1.pid"
  local current_pid current_token current_fingerprint
  # Expiry can find a delayed old process while a newer run owns the shared PID
  # file. Signal only the exact kernel identity; never replace or trust that
  # shared file in order to stop the old process.
  matches_owned_process "$name" "$pid" "$token" "$fingerprint" || return 3
  kill "$pid" 2>/dev/null || true
  if ! wait_owned_dead "$name" "$pid" "$token" "$fingerprint"; then
    # macOS has no pidfd. Revalidate exact executable + argv + token + start
    # fingerprint immediately before the last-resort signal.
    matches_owned_process "$name" "$pid" "$token" "$fingerprint" \
      || return 3
    kill -KILL "$pid" 2>/dev/null || true
    if ! wait_owned_dead "$name" "$pid" "$token" "$fingerprint"; then
      die "$name pid $pid would not stop"
      return 1
    fi
  fi
  print -- "stopped $name pid=$pid"
  rig_event process_stopped name "$name" pid "$pid"
  if [[ "$name" == emulator ]]; then
    remove_ircama_pid_lock_after_stop "$pid" || true
  fi
  if [[ -f "$pid_file" ]] \
      && read -r current_pid current_token current_fingerprint < "$pid_file" \
      && [[ "$current_pid" == "$pid" && "$current_token" == "$token" ]]; then
    # A bridge may have published only pid+token before being interrupted. It
    # is safe to remove that unchanged partial record after stopping the exact
    # token-owned process, but never remove another valid fingerprint or token.
    if [[ "$current_fingerprint" == "$fingerprint" \
        || ! "$current_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
      rm -f "$pid_file"
    fi
  fi
}

_stop_discovered_owned_locked() {
  local name=$1 pid_hint=${2:-} matches discovered_pid token fingerprint rc
  local -a candidates
  matches=$(discover_owned_processes "$name" || true)
  [[ -n "$matches" ]] || return 4
  candidates=("${(@f)matches}")
  if (( ${#candidates[@]} != 1 )); then
    die "multiple exact owned $name processes prevent safe cleanup"
    return 2
  fi
  read -r discovered_pid token fingerprint <<< "${candidates[1]}"
  if [[ "$pid_hint" == <-> && "$pid_hint" != "$discovered_pid" ]] \
      && kill -0 "$pid_hint" 2>/dev/null; then
    die "live unowned $name pid=$pid_hint conflicts with discovered pid=$discovered_pid"
    return 2
  fi
  if _stop_owned_identity_locked \
      "$name" "$discovered_pid" "$token" "$fingerprint"; then
    return 0
  else
    rc=$?
  fi
  if (( rc == 3 )) && [[ -z "$(discover_owned_processes "$name" || true)" ]]; then
    return 0
  fi
  return "$rc"
}

stop_one() {
  local name=$1 rc=0 lock_file="$STATE/$1.stop.lock"
  local -i lock_fd=0
  [[ ! -L "$lock_file" ]] || { die "unsafe $name stop lock symlink"; return 1; }
  touch "$lock_file" || { die "could not create $name stop lock"; return 1; }
  chmod 600 "$lock_file"
  require_owned_regular_file "$lock_file" || return 1
  if ! zsystem flock -t 10 -f lock_fd "$lock_file"; then
    die "$name stop lock stayed busy for 10 seconds"
    return 1
  fi
  _stop_one_locked "$@" || rc=$?
  zsystem flock -u "$lock_fd" || rc=1
  return "$rc"
}

stop() {
  local owner rc=0 stop_rc=0
  stop_one bridge || rc=$?
  stop_one emulator || {
    stop_rc=$?
    (( rc != 0 )) || rc=$stop_rc
  }
  owner=$(port_owner)
  if [[ -n "$owner" ]]; then
    die "port $PORT still has listener pid=$owner (not killed)"
    return 1
  fi
  if (( rc != 0 )); then
    die "one or more rig processes could not be safely stopped"
    return 1
  fi
}

purge_evidence() {
  local name matches owner
  stop || return 1
  for name in bridge emulator; do
    matches=$(discover_owned_processes "$name" || true)
    if [[ -n "$matches" ]]; then
      die "refusing to purge while an owned $name process still exists"
      return 1
    fi
  done
  owner=$(port_owner)
  if [[ -n "$owner" ]]; then
    die "refusing to purge while port $PORT has listener pid=$owner"
    return 1
  fi
  # Keep state lock inodes (per-run stop locks and any pre-upgrade legacy
  # controller lock). Removing a locked pathname lets another process create a
  # different inode and bypass mutual exclusion. The current host-global
  # controller lock lives outside STATE and is never part of evidence purging.
  find "$STATE" -maxdepth 1 -type f ! -name '*.lock' -delete
  rm -f "$BRIDGE_LOG" "$CLIENT_LOG"
  print -- "purged stopped-rig evidence; state lock inodes preserved in $STATE"
}

classify_expiry_target() {
  # Return 0 when the requested emulator is ready to stop, 3 only when a valid
  # newer run owns the state, and 4 when the requested process is already
  # absent with no listener. Any ambiguous process/listener is an error.
  local requested_token=$1 matches current current_pid current_token
  local current_fingerprint owner current_valid=0
  EXPIRY_PID=''
  EXPIRY_FINGERPRINT=''
  if current=$(owned_pid emulator 2>/dev/null); then
    read -r current_pid current_token current_fingerprint \
      < "$STATE/emulator.pid" || true
    current_valid=1
    if [[ "$current_token" == "$requested_token" ]]; then
      EXPIRY_PID=$current_pid
      EXPIRY_FINGERPRINT=$current_fingerprint
      return 0
    fi
  fi
  matches=$(list_owned_processes emulator "$requested_token" || true)
  if [[ -n "$matches" ]]; then
    local -a candidates
    candidates=("${(@f)matches}")
    if (( ${#candidates[@]} == 1 )); then
      EXPIRY_PID=${candidates[1]%% *}
      EXPIRY_FINGERPRINT=${candidates[1]#* }
      return 0
    fi
    die "multiple token-owned emulator processes prevent safe expiry"
    return 2
  fi
  (( current_valid )) && return 3
  owner=$(port_owner)
  if [[ -n "$owner" ]]; then
    die "unexplained listener pid=$owner prevents safe expiry"
    return 2
  fi
  return 4
}

_expire_locked() {
  local requested_token=$1 classification rc
  if classify_expiry_target "$requested_token"; then
    classification=0
  else
    classification=$?
  fi
  case "$classification" in
    3)
      rig_event expiration_ignored reason newer_valid_owner
      return 0
      ;;
    4)
      rig_event expiration_ignored reason already_absent
      return 0
      ;;
    0) ;;
    *) return "$classification" ;;
  esac

  if _stop_owned_identity_locked \
      emulator "$EXPIRY_PID" "$requested_token" "$EXPIRY_FINGERPRINT"; then
    :
  else
    rc=$?
    if (( rc != 3 )); then
      return "$rc"
    fi
  fi

  # Reclassify after the stop: a concurrent newer run is valid, an absent old
  # run is success, but an unexplained listener or surviving old process fails.
  if classify_expiry_target "$requested_token"; then
    classification=0
  else
    classification=$?
  fi
  case "$classification" in
    3)
      rig_event expiration_ignored reason newer_valid_owner
      return 0
      ;;
    4)
      rig_event rig_expired port "$PORT"
      return 0
      ;;
    0)
      die "token-owned emulator survived its expiry stop"
      return 1
      ;;
    *) return "$classification" ;;
  esac
}

expire() {
  local requested_token=$1 rc=0
  local -i lock_fd=0
  local lock_file="$STATE/emulator.stop.lock"
  [[ ! -L "$lock_file" ]] || { die "unsafe emulator stop lock symlink"; return 1; }
  touch "$lock_file" || { die "could not create emulator stop lock"; return 1; }
  chmod 600 "$lock_file"
  require_owned_regular_file "$lock_file" || return 1
  if ! zsystem flock -t 10 -f lock_fd "$lock_file"; then
    die "emulator stop lock stayed busy for 10 seconds"
    return 1
  fi
  _expire_locked "$requested_token" || rc=$?
  zsystem flock -u "$lock_fd" || rc=1
  return "$rc"
}

status_snapshot() {
  local emulator=$1 bridge=$2 owner
  [[ "$(owned_pid emulator 2>/dev/null || true)" == "$emulator" ]] || return 1
  [[ "$(owned_pid bridge 2>/dev/null || true)" == "$bridge" ]] || return 1
  owner=$(port_owner)
  [[ "$owner" == "$emulator" ]] || return 1
  [[ "$(listener_endpoint "$emulator")" == "127.0.0.1:$PORT" ]] || return 1
  verify_bridge_health "$bridge"
}

status() {
  local emulator bridge owner
  if ! emulator=$(owned_pid emulator); then
    die "emulator is not a live owned process"
    return 1
  fi
  if ! bridge=$(owned_pid bridge); then
    die "bridge is not a live owned process"
    return 1
  fi
  owner=$(port_owner)
  if [[ "$owner" != "$emulator" ]]; then
    die "port $PORT owner is ${owner:-none}, expected emulator pid=$emulator"
    return 1
  fi
  if [[ "$(listener_endpoint "$emulator")" != "127.0.0.1:$PORT" ]]; then
    die "emulator listener is not restricted to 127.0.0.1:$PORT"
    return 1
  fi
  if ! verify_bridge_health "$bridge"; then
    die "bridge has no fresh advertising-health event"
    return 1
  fi
  # Revalidate the complete snapshot immediately before recording success. The
  # bridge may naturally expire while the earlier health record is inspected.
  if ! status_snapshot "$emulator" "$bridge"; then
    die "rig ownership or advertising changed during the status check"
    return 1
  fi
  rig_event status_ok emulator_pid "$emulator" bridge_pid "$bridge" port "$PORT"
  print -- "healthy emulator_pid=$emulator bridge_pid=$bridge port=$PORT"
}

START_STATUS_ERROR=''
wait_for_rig_ready() {
  local token=$1
  local -i attempts=${2:-100} attempt=0
  local delay=${3:-0.2} bridge_pid status_output=''
  START_STATUS_ERROR=''
  (( attempts > 0 )) || return 1
  while (( attempt < attempts )); do
    (( attempt += 1 ))
    status_output=''
    # LaunchServices can expose the new Python process while its kernel argv or
    # executable snapshot is still settling. Retry the complete fail-closed
    # status check, not just the weaker PID recovery + advertising predicate.
    if recover_owned_pid_file bridge "$token" \
        && bridge_pid=$(owned_pid bridge "$token" 2>/dev/null); then
      if status_output=$(status 2>&1); then
        print -r -- "$status_output"
        return 0
      fi
      START_STATUS_ERROR=$status_output
    fi
    grep -q '"event":"fatal"' "$BRIDGE_LOG" 2>/dev/null && break
    (( attempt < attempts )) && sleep "$delay"
  done
  return 1
}

command=${1:---start}
# Natural bridge expiry must never wait behind dependency installation or app
# bundle construction. Its token-qualified stop path revalidates the PID file
# and live process immediately before signaling, so it is safe against a newer
# run without the controller lock and cannot strand the old emulator if setup
# hangs while holding that lock.
if [[ "$command" == --expire ]]; then
  [[ "$#" -eq 2 && "$2" =~ ^[0-9a-f]{32}$ ]] \
    || { die "invalid internal expiry token"; exit 2; }
  expire "$2"
  exit 0
fi

CONTROLLER_LOCK_HELD=0
START_CLEANUP_ARMED=0
START_EMULATOR_MAY_EXIST=0
START_BRIDGE_MAY_EXIST=0
START_TOKEN=''
trap on_exit EXIT
trap on_error ZERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM HUP
acquire_controller_lock

case "$command" in
  --stop) stop; exit 0 ;;
  --status) status; exit 0 ;;
  --purge-evidence) purge_evidence; exit 0 ;;
  --start|--probe) ;;
  *) die "usage: $0 [--start|--status|--stop|--probe|--purge-evidence]" || true; exit 2 ;;
esac

stage_runtime_scripts() {
  local name source destination temporary mode
  if [[ -e "$RUNTIME" || -L "$RUNTIME" ]]; then
    require_owned_directory "$RUNTIME" || return 1
  else
    mkdir -m 700 "$RUNTIME"
  fi
  chmod 700 "$RUNTIME"
  # A LaunchServices app can be denied access to protected source trees such
  # as ~/Documents even when its terminal parent can read them. Execute only
  # owner-private staged copies, including the controller used at natural
  # expiry, so startup and cleanup never depend on that inherited permission.
  for name in run.sh bridge.py probe.py emulator_entrypoint.py process_identity.py; do
    source="$HERE/$name"
    destination="$RUNTIME/$name"
    temporary="$RUNTIME/.$name.new.$$"
    require_owned_regular_file "$source" || return 1
    [[ ! -e "$temporary" && ! -L "$temporary" ]] \
      || { die "stale runtime staging file: $temporary"; return 1; }
    cp "$source" "$temporary"
    mode=600
    [[ "$name" == run.sh ]] && mode=700
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$destination"
    require_owned_regular_file "$destination" || return 1
  done
}

# Exact pins cover direct and transitive dependencies for the supported macOS
# Python 3.14 rig. ELM's sdist imports pkg_resources, so build isolation stays
# disabled and the GitHub run-number environment leak is explicitly removed.
if [[ -e "$VENV" || -L "$VENV" ]]; then
  require_owned_directory "$VENV" || exit 1
fi
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
require_owned_directory "$VENV" || exit 1
require_owned_regular_file "$VENV/bin/pip" || exit 1
"$VENV/bin/pip" install --quiet --require-hashes \
  -r "$HERE/requirements.bootstrap"
env -u GITHUB_RUN_NUMBER "$VENV/bin/pip" install --quiet \
  --require-hashes --no-build-isolation -r "$HERE/requirements.lock"
"$VENV/bin/pip" check > "$STATE/pip-check.txt"
"$VENV/bin/pip" freeze | LC_ALL=C sort > "$STATE/dependency-manifest.txt"
diff -u "$HERE/requirements.lock.freeze" "$STATE/dependency-manifest.txt" \
  > "$STATE/dependency-diff.txt" \
  || die "installed dependency set differs; see $STATE/dependency-diff.txt"
stage_runtime_scripts || die "could not stage private BLE host runtime"

# CoreBluetooth requires a responsible app bundle with Bluetooth purpose text.
REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')
PREFIX=$("$VENV/bin/python" -c 'import sys; print(sys.base_prefix)')
SITE=$("$VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REAL" "$APP/Contents/MacOS/BleHost"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BleHost</string>
  <key>CFBundleIdentifier</key><string>local.telltale.blehost</string>
  <key>CFBundleName</key><string>BleHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSEnvironment</key><dict>
    <key>PYTHONHOME</key><string>${PREFIX}</string>
    <key>PYTHONPATH</key><string>${SITE}</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Advertises a simulated ELM327 for local Telltale testing.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Advertises a simulated ELM327 for local testing.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" \
  || die "ad-hoc signing $APP failed"

if [[ "${1:---start}" == --probe ]]; then
  rm -f "$CLIENT_LOG"
  open -n -a "$APP" --args -u "$RUNTIME/probe.py"
  print -- "probe launched; results: $CLIENT_LOG"
  exit 0
fi

stop
foreign=$(port_owner)
[[ -z "$foreign" ]] || die "refusing to start: port $PORT belongs to pid=$foreign"
token=$(/usr/bin/python3 -c 'import secrets; print(secrets.token_hex(16))')
START_TOKEN=$token
START_CLEANUP_ARMED=1
rig_event start_requested port "$PORT"

seconds=${RIG_SECONDS:-900}
delay=${RIG_RESPONSE_DELAY_MS:-0}
chunk=${RIG_NOTIFY_CHUNK_SIZE:-20}
drop=${RIG_UPSTREAM_DROP_ON_COMMAND:-0}
gatt_drop=${RIG_GATT_DROP_ON_COMMAND:-0}
gatt_restart=${RIG_GATT_RESTART_MS:-0}
# CoreBluetooth exposes advertising/subscription state but no peripheral-side
# operation that forcibly disconnects a central. Refuse instead of mislabeling
# an upstream silence or advertising stop as a BLE link loss.
if [[ "$gatt_drop" != 0 || "$gatt_restart" != 0 ]]; then
  die "GATT drop/restart is unsupported: CoreBluetooth cannot force central disconnect"
fi
# Validate fault controls without importing bless/CoreBluetooth.
PYTHONPATH="$HERE" "$VENV/bin/python" -c \
  'from bridge import FaultConfig; import sys; FaultConfig.from_strings(*sys.argv[1:])' \
  "$delay" "$chunk" "$drop" \
  2>/dev/null \
  || die "invalid delay/chunk/RIG_UPSTREAM_DROP_ON_COMMAND fault control"
[[ "$seconds" == <-> && "$seconds" -gt 0 ]] || die "RIG_SECONDS must be positive"

# ELM's supported daemon mode survives both stdin EOF and the caller shell.
# The entrypoint relocates Ircama's own daemon lock from its package-global
# /tmp default into this controller's owner-only state directory.
prepare_ircama_pid_lock_for_start || die "unsafe Ircama PID lock: $IRCAMA_PID_LOCK"
START_EMULATOR_MAY_EXIST=1
TELLTALE_RIG_TOKEN="$token" "$VENV/bin/python" "$RUNTIME/emulator_entrypoint.py" \
  --pid-directory "$STATE" -d -n "$PORT" -s car \
  >"$STATE/emulator.log" 2>&1 \
  || die "emulator daemon launch failed; see $STATE/emulator.log"
emulator_pid=''
emulator_fingerprint=''
# python-daemon's parent exits before its detached child writes the lock file.
# Poll the file, process token and listener together; reading it once races and
# can also accept a stale PID from a previous crash.
for _ in {1..50}; do
  candidate=$(cat "$IRCAMA_PID_LOCK" 2>/dev/null || true)
  owner=$(port_owner)
  if emulator_fingerprint=$(process_fingerprint emulator "$candidate" "$token" 2>/dev/null) \
      && [[ "$owner" == "$candidate" ]] \
      && [[ "$(listener_endpoint "$candidate")" == "127.0.0.1:$PORT" ]]; then
    emulator_pid=$candidate
    break
  fi
  sleep 0.2
done
[[ "$emulator_pid" == <-> ]] || die \
  "emulator did not publish a token-owned listening PID; see $STATE/emulator.log and: lsof -nP -iTCP:$PORT"
print -- "$emulator_pid $token $emulator_fingerprint" > "$STATE/emulator.pid"

for _ in {1..50}; do
  owner=$(port_owner)
  [[ "$owner" == "$emulator_pid" ]] && break
  kill -0 "$emulator_pid" 2>/dev/null || break
  sleep 0.2
done
owner=$(port_owner)
if [[ "$owner" != "$emulator_pid" ]]; then
  stop_one emulator || true
  die "emulator failed ownership/readiness check; see $STATE/emulator.log"
fi
[[ "$(listener_endpoint "$emulator_pid")" == "127.0.0.1:$PORT" ]] \
  || { stop_one emulator || true; die "emulator listener escaped loopback"; }

rm -f "$BRIDGE_LOG" "$STATE/bridge.pid"
START_BRIDGE_MAY_EXIST=1
open -n -a "$APP" --args -u "$RUNTIME/bridge.py" \
  "$seconds" "$STATE/bridge.pid" "$delay" "$chunk" "$drop" "$token" \
  "$TMP_ROOT" \
  || { stop || true; die "LaunchServices could not start the BLE bridge"; }
if ! wait_for_rig_ready "$token"; then
  last_status_error=$START_STATUS_ERROR
  stop || true
  [[ -z "$last_status_error" ]] \
    || print -u2 -- "ble rig: last readiness error: $last_status_error"
  die "bridge failed readiness check; see $BRIDGE_LOG"
fi

rig_event rig_ready emulator_pid "$emulator_pid"
START_CLEANUP_ARMED=0
print -- "advertising TelltaleELM for ${seconds}s"
print -- "bridge JSONL: $BRIDGE_LOG"
print -- "state/evidence: $STATE"
print -- "stop: $0 --stop"
