#!/bin/zsh -f
set -euo pipefail
umask 077

die() { print -u2 -- "telemetry memory rig: $*"; exit 1; }

[[ $# == 1 ]] || die "usage: tool/telemetry_memory_rig/run.sh <adb-serial>"

reject_host_build_overrides() {
  local entry name
  while IFS= read -r entry; do
    name=${entry%%=*}
    case "$name" in
      GRADLE_HOME|GRADLE_USER_HOME|GRADLE_OPTS|GRADLE_RO_DEP_CACHE|\
      JAVA_HOME|JAVA_OPTS|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|\
      ANDROID_HOME|ANDROID_SDK_ROOT|ANDROID_SDK_HOME|ANDROID_USER_HOME|\
      ANDROID_NDK_HOME|ANDROID_NDK_ROOT|ANDROID_NDK_PATH|\
      FLUTTER_ALREADY_LOCKED|FLUTTER_ROOT|FLUTTER_TOOL_ARGS|\
      FLUTTER_STORAGE_BASE_URL|\
      TELLTALE_GATE_C_FLUTTER_ROOT|TELLTALE_GATE_C_JDK_ROOT|\
      TELLTALE_GATE_C_SANDBOX_*|\
      TELLTALE_GATE_C_PROCESS_SCOPE|TELLTALE_GATE_C_LAUNCH_*|\
      DART_VM_OPTIONS|KOTLIN_DAEMON_JVM_OPTIONS|PUB_CACHE|PUB_ENVIRONMENT|\
      ADB_SERVER_SOCKET|ADB_SERVER_ADDRESS|ANDROID_ADB_SERVER_PORT|\
      DYLD_*|LD_PRELOAD|LD_LIBRARY_PATH|\
      ORG_GRADLE_PROJECT_*|PYTHON*|ZDOTDIR)
        die "host build override is not allowed for Gate C: $name"
        ;;
    esac
  done < <(env)
}
reject_host_build_overrides
export PYTHONNOUSERSITE=1

SERIAL=$1
HERE=${0:a:h}
APP_ROOT=${HERE:h:h}
HOST_HOME=${HOME:A}
PYTHON_LAUNCHER_COMMAND=$(command -v python3 2>/dev/null || true)
[[ -n "$PYTHON_LAUNCHER_COMMAND" ]] || die "python3 is unavailable"
PYTHON_LAUNCHER=${PYTHON_LAUNCHER_COMMAND:A}
[[ -x "$PYTHON_LAUNCHER" && -f "$PYTHON_LAUNCHER" \
  && ! -L "$PYTHON_LAUNCHER" ]] \
  || die "canonical Python launcher is missing or unsafe: $PYTHON_LAUNCHER"
PYTHON_RUNTIME_COMMAND=$("$PYTHON_LAUNCHER" -I -S -B - \
  "$PYTHON_LAUNCHER" <<'PY'
import ctypes, os, pathlib, stat, sys

launcher = pathlib.Path(sys.argv[1])
actual = pathlib.Path(sys.executable).resolve(strict=True)
if actual != launcher:
    raise SystemExit(f'Python launcher binding mismatch: {actual} != {launcher}')

def validate_path(path, *, directory=False):
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise SystemExit(f'noncanonical Python path: {path}')
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f'symlinked Python path: {current}')
        if current != path and not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f'non-directory Python ancestor: {current}')
    metadata = os.lstat(path)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_type(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or (not directory and metadata.st_nlink != 1)
        or metadata.st_mode & 0o022
        or (not directory and not os.access(path, os.X_OK))
    ):
        raise SystemExit(f'unsafe Python path metadata: {path}')

validate_path(launcher)
root = pathlib.Path(sys.base_prefix).resolve(strict=True)
validate_path(root, directory=True)
if not launcher.is_relative_to(root):
    raise SystemExit(f'Python launcher is outside its runtime root: {launcher}')
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
buffer = ctypes.create_string_buffer(4096)
length = libproc.proc_pidpath(os.getpid(), buffer, len(buffer))
if length <= 0:
    raise OSError(ctypes.get_errno(), 'proc_pidpath failed')
runtime = pathlib.Path(os.fsdecode(buffer.value))
validate_path(runtime)
if not runtime.is_relative_to(root):
    raise SystemExit(f'Python runtime executable is outside its root: {runtime}')
print(runtime)
PY
) || die "Python kernel runtime discovery failed"
[[ -n "$PYTHON_RUNTIME_COMMAND" ]] \
  || die "Python kernel runtime discovery returned no executable"
PYTHON=${PYTHON_RUNTIME_COMMAND:A}
[[ -x "$PYTHON" && -f "$PYTHON" && ! -L "$PYTHON" ]] \
  || die "canonical Python runtime is missing or unsafe: $PYTHON"

gate_c_monotonic_ns() {
  local value
  value=$("$PYTHON" -I -S -B -c 'import time; print(time.monotonic_ns())') \
    || return 1
  [[ "$value" == <-> && "$value" != 0 ]] || return 1
  print -r -- "$value"
}

gate_c_sleep_to_cadence() {
  local deadline_ns=$1 now_ns remaining_ns sleep_seconds
  [[ "$deadline_ns" == <-> && "$deadline_ns" != 0 ]] || return 1
  now_ns=$(gate_c_monotonic_ns) || return 1
  (( now_ns <= deadline_ns )) || return 0
  remaining_ns=$(( deadline_ns - now_ns ))
  (( remaining_ns > 0 )) || return 0
  printf -v sleep_seconds '%.9f' "$(( remaining_ns / 1000000000.0 ))"
  sleep "$sleep_seconds"
}
PYTHON_RUNTIME_ROOT=$("$PYTHON" -I -S -B - "$PYTHON" <<'PY'
import ctypes, os, pathlib, stat, sys

expected = pathlib.Path(sys.argv[1])
actual = pathlib.Path(sys.executable).resolve(strict=True)
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
buffer = ctypes.create_string_buffer(4096)
length = libproc.proc_pidpath(os.getpid(), buffer, len(buffer))
if length <= 0:
    raise OSError(ctypes.get_errno(), 'proc_pidpath failed')
kernel = pathlib.Path(os.fsdecode(buffer.value)).resolve(strict=True)
if actual != expected or kernel != expected:
    raise SystemExit(
        f'Python runtime binding mismatch: {actual} != {kernel} != {expected}'
    )
if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode):
    raise SystemExit('Python runtime isolation flags are incomplete')
status = os.lstat(actual)
if (
    not stat.S_ISREG(status.st_mode)
    or status.st_nlink != 1
    or status.st_uid != os.getuid()
    or status.st_mode & 0o022
):
    raise SystemExit(f'Python executable metadata is unsafe: {actual}')
for candidate in (actual, pathlib.Path(sys.base_prefix)):
    current = pathlib.Path(candidate.anchor)
    for part in candidate.parts[1:]:
        current /= part
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise SystemExit(f'symlinked Python runtime path: {current}')
root = pathlib.Path(sys.base_prefix).resolve(strict=True)
if not root.is_dir():
    raise SystemExit(f'Python runtime root is not a directory: {root}')
print(root)
PY
) || die "Python kernel runtime validation failed"
"$PYTHON" -I -S -B - <<'PY' \
  || die "inherited file descriptor is not allowed for Gate C"
import errno, fcntl, os

unexpected = []
for entry in os.listdir('/dev/fd'):
    if not entry.isdigit() or int(entry) < 3:
        continue
    descriptor = int(entry)
    try:
        fcntl.fcntl(descriptor, fcntl.F_GETFD)
    except OSError as error:
        if error.errno == errno.EBADF:
            continue
        raise
    unexpected.append(descriptor)
if unexpected:
    raise SystemExit(f'unexpected inherited descriptors: {sorted(unexpected)}')
PY
PYTHON_SHA256=$(shasum -a 256 "$PYTHON" | awk '{print $1}')
[[ ${#PYTHON_SHA256} == 64 && "$PYTHON_SHA256" != *[^0-9a-f]* ]] \
  || die "could not bind the Python executable digest"
FLUTTER=${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}
DART=${DART:-${FLUTTER:h}/dart}
ADB=${ADB:-adb}
SEALED_SDK_EXEC="$HERE/sealed_sdk_exec.sh"
ANDROID_SDK_SANDBOX_EXEC="$HERE/android_sdk_sandbox_exec.sh"
ANDROID_SDK_SANDBOX_PREFLIGHT="$HERE/android_sdk_sandbox_preflight.py"
ANDROID_SDK_SANDBOX_PROFILE="$HERE/android_sdk_write_deny.sb"
ANDROID_SDK_SANDBOX_PROBE="$HERE/android_sdk_sandbox_probe.py"
PROCESS_SCOPE_HELPER="$HERE/process_scope.py"
SCOPED_COMMAND="$HERE/scoped_command.py"
source "$HERE/bounded_reap.sh"
SOURCE_GUARD_READY_TIMEOUT_MS=300000

wait_for_live_guard_ready() {
  local pid=$1 ready_file=$2 timeout_ms=$3
  [[ "$pid" == <-> && "$timeout_ms" == <-> && $timeout_ms -gt 0 ]] \
    || return 64
  "$PYTHON" -I -S -B - "$pid" "$ready_file" "$timeout_ms" <<'PY'
import errno
import os
import pathlib
import stat
import sys
import time

try:
    pid = int(sys.argv[1])
    ready_file = pathlib.Path(sys.argv[2])
    timeout_ms = int(sys.argv[3])
except (IndexError, ValueError):
    raise SystemExit(64)
if (
    pid <= 0
    or not ready_file.is_absolute()
    or timeout_ms <= 0
    or timeout_ms > 600_000
):
    raise SystemExit(64)


def require_live_child() -> None:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(2)
    except OSError:
        raise SystemExit(127)


try:
    previous_ns = time.monotonic_ns()
    deadline_ns = previous_ns + timeout_ms * 1_000_000
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
except (AttributeError, OSError):
    raise SystemExit(127)

while True:
    require_live_child()
    descriptor = None
    try:
        descriptor = os.open(ready_file, flags)
    except FileNotFoundError:
        pass
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise SystemExit(3)
    else:
        try:
            metadata = os.fstat(descriptor)
        except OSError:
            raise SystemExit(3)
        finally:
            os.close(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise SystemExit(3)
        require_live_child()
        raise SystemExit(0)
    try:
        now_ns = time.monotonic_ns()
    except Exception:
        raise SystemExit(127)
    if now_ns < previous_ns:
        raise SystemExit(127)
    previous_ns = now_ns
    if now_ns >= deadline_ns:
        raise SystemExit(1)
    try:
        time.sleep(min(0.05, (deadline_ns - now_ns) / 1_000_000_000))
    except Exception:
        raise SystemExit(127)
PY
}

PACKAGE=com.cbstudio.telltale.rig
FIELD_PACKAGE=com.cbstudio.telltale
source "$HERE/adb_state_guard.sh"
if [[ -n ${TELEMETRY_RIG_EVIDENCE_DIR:-} ]]; then
  EVIDENCE=$("$PYTHON" -I -S -B "$HERE/prepare_evidence_dir.py" \
    wrapper-runner --app-root "$APP_ROOT" \
    --outer "$TELEMETRY_RIG_EVIDENCE_DIR")
else
  EVIDENCE=$("$PYTHON" -I -S -B "$HERE/prepare_evidence_dir.py" \
    default --app-root "$APP_ROOT")
fi
[[ -d "$EVIDENCE" && ! -L "$EVIDENCE" ]] \
  || die "evidence helper did not create a safe directory"
PROCESS_SCOPE_AUTHORITY_DIR="$EVIDENCE/process-scope-authorities"
mkdir "$PROCESS_SCOPE_AUTHORITY_DIR"
chmod 700 "$PROCESS_SCOPE_AUTHORITY_DIR"
[[ -d "$PROCESS_SCOPE_AUTHORITY_DIR" \
  && ! -L "$PROCESS_SCOPE_AUTHORITY_DIR" \
  && -O "$PROCESS_SCOPE_AUTHORITY_DIR" ]] \
  || die "process-scope authority directory is unsafe"
PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR="$EVIDENCE/process-scope-reference-authorities"
mkdir "$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR"
chmod 700 "$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR"
[[ -d "$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR" \
  && ! -L "$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR" \
  && -O "$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR" ]] \
  || die "process-scope reference-authority directory is unsafe"
GATE_OWNER_ROOT_PID=$$
PROCESS_SCOPE_LAUNCH_ATTEMPT=0
shasum -a 256 "$PYTHON" > "$EVIDENCE/python-executable.pre.sha256"
GRADLE_TEMP_PARENT=''
GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT=0
GRADLE_FORENSIC_RETENTION_LATCH=0
FINAL_PROCESS_SCOPE_EVIDENCE=''
ISOLATED_USER_TEMP_PARENT=''
FLUTTER_GRADLE_GENERATED_DIRTY=0
FLUTTER_GRADLE_GENERATED_CLEANUP_ATTEMPT=0
BOOTSTRAP_SOURCE_GUARD_PID=''
BOOTSTRAP_SOURCE_GUARD_STOP=''
BOOTSTRAP_SOURCE_GUARD_EVENTS=''
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE=''
BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY=''
SOURCE_GUARD_REFERENCE_AUTHORITY=''
SCOPE_REFERENCE_ARGS=()

quiesce_gradle_process_scope() {
  local scope_label=$1 scope_evidence=$2 scope_exit authority
  local -a authority_paths authority_args
  [[ -n "$scope_label" && "$scope_label" != *[^a-z0-9-]* ]] \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 64; }
  [[ -n ${ANDROID_SDK_SANDBOX_RUN_TEMP:-} \
    && -n ${GRADLE_USER_HOME:-} ]] \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 64; }
  authority_paths=("$PROCESS_SCOPE_AUTHORITY_DIR"/*.process-authority.json(N.))
  authority="$EVIDENCE/android-sdk-sandbox-probe.process-authority.json"
  if [[ -e "$authority" || -L "$authority" ]]; then
    [[ -f "$authority" && ! -L "$authority" && -O "$authority" ]] \
      || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 65; }
    authority_paths+=("$authority")
  fi
  authority_paths=(${(on)authority_paths})
  if (( ${#authority_paths} == 0 )); then
    (( PROCESS_SCOPE_LAUNCH_ATTEMPT == 0 )) && return 0
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return 66
  fi
  for authority in "${authority_paths[@]}"; do
    authority_args+=(--authority "$authority")
  done
  if "$PYTHON" -I -S -B "$PROCESS_SCOPE_HELPER" audit \
    "${authority_args[@]}" \
    --evidence "$scope_evidence"; then
    scope_exit=0
  else
    scope_exit=$?
  fi
  if (( scope_exit != 0 )); then
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return "$scope_exit"
  fi
  validate_gradle_process_scope_evidence \
    "$scope_label" "$scope_evidence" "${authority_paths[@]}"
  scope_exit=$?
  if (( scope_exit != 0 )); then
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return "$scope_exit"
  fi
}

validate_gradle_process_scope_evidence() {
  local scope_label=$1 scope_evidence=$2
  local -a reference_paths
  shift 2
  [[ -n "$scope_label" && "$scope_label" != *[^a-z0-9-]* ]] || return 64
  (( $# > 0 )) || return 64
  if [[ "$scope_label" != cleanup ]]; then
    if [[ ${BOOTSTRAP_SOURCE_GUARD_PID:-} == <-> \
      && -n ${BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY:-} ]] \
      && kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null; then
      reference_paths+=("$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY")
    fi
    if [[ ${SOURCE_GUARD_PID:-} == <-> \
      && -n ${SOURCE_GUARD_REFERENCE_AUTHORITY:-} ]] \
      && kill -0 "$SOURCE_GUARD_PID" 2>/dev/null; then
      reference_paths+=("$SOURCE_GUARD_REFERENCE_AUTHORITY")
    fi
  fi
  "$PYTHON" -I -S -B - "$scope_evidence" "$scope_label" \
    "$GATE_OWNER_ROOT_PID" "$GRADLE_USER_HOME" \
    "$ISOLATED_USER_TEMP_PARENT" "$HOME" \
    "$ANDROID_SDK_SANDBOX_RUN_TEMP" \
    "$KOTLIN_PROJECT_PERSISTENT_DIR" "$KOTLIN_DAEMON_RUN_FILES_DIR" \
    "${#reference_paths}" "${reference_paths[@]}" \
    "$@" <<'PY'
import hashlib, json, pathlib, re, sys

evidence_path = pathlib.Path(sys.argv[1])
label = sys.argv[2]
owner_root_pid = int(sys.argv[3])
root_names = (
    'gradleUserHome', 'isolatedUserRoot', 'home', 'sandboxRunTemp',
    'kotlinProjectPersistentDir', 'kotlinDaemonRunFilesDir',
)
roots = {
    name: str(pathlib.Path(path).resolve(strict=True))
    for name, path in zip(root_names, sys.argv[4:10], strict=True)
}
reference_count = int(sys.argv[10])
reference_paths = [
    pathlib.Path(path) for path in sys.argv[11:11 + reference_count]
]
authority_paths = [pathlib.Path(path) for path in sys.argv[11 + reference_count:]]
value = json.loads(evidence_path.read_text(encoding='utf-8'))
required = {
    'version', 'status', 'marker', 'ownerRoot', 'roots', 'authorities',
    'authorizedSessions', 'startedMonotonicNs', 'endedMonotonicNs',
    'stoppedProcesses', 'termSentProcesses', 'killSentProcesses',
    'remainingOwnedProcesses', 'foreignProcesses', 'inspectionLimitations',
    'referenceInspection', 'referenceAuthorities', 'referenceExemptProcesses',
}
audit_only = label == 'cleanup'
if audit_only:
    required.add('mode')
identity_keys = {'pid', 'ppid', 'pgid', 'sid', 'uid', 'startSec', 'startUsec'}
record_keys = {
    'identity', 'state', 'executable', 'argv', 'environmentSha256', 'cwd',
    'root', 'openVnodePaths', 'inspectionErrors', 'vnodeEvidenceMethod',
    'vnodeEvidenceComplete',
}

def valid_identity(item):
    return (
        isinstance(item, dict)
        and set(item) == identity_keys
        and all(type(item[key]) is int for key in identity_keys)
        and min(item['pid'], item['pgid'], item['sid'], item['uid'] + 1,
                item['startSec'], item['startUsec'] + 1) > 0
    )

def valid_record(item):
    return (
        isinstance(item, dict)
        and set(item) == record_keys
        and valid_identity(item.get('identity'))
        and type(item.get('state')) is int
        and isinstance(item.get('executable'), str)
        and isinstance(item.get('argv'), list)
        and all(isinstance(part, str) for part in item['argv'])
        and re.fullmatch(r'[0-9a-f]{64}', item.get('environmentSha256', ''))
            is not None
        and (item.get('cwd') is None or isinstance(item['cwd'], str))
        and (item.get('root') is None or isinstance(item['root'], str))
        and isinstance(item.get('openVnodePaths'), list)
        and all(isinstance(path, str) and path.startswith('/')
                for path in item['openVnodePaths'])
        and item.get('inspectionErrors') == []
        and item.get('vnodeEvidenceMethod') in {'libproc', 'sealed-lsof'}
        and item.get('vnodeEvidenceComplete') is True
    )

authorities = []
authority_entries = []
for path in authority_paths:
    raw = path.read_bytes()
    authority = json.loads(raw)
    if set(authority) != {
        'version', 'launchId', 'ownerRoot', 'supervisor', 'leader', 'wrapper',
        'roots', 'cwd',
    }:
        raise SystemExit('process authority schema is invalid')
    if (
        authority.get('version') != 2
        or re.fullmatch(r'[0-9a-f]{32}', authority.get('launchId', '')) is None
        or not valid_identity(authority.get('ownerRoot'))
        or not valid_identity(authority.get('supervisor'))
        or not valid_identity(authority.get('leader'))
        or authority['ownerRoot']['pid'] != owner_root_pid
        or authority['leader']['pid'] != authority['leader']['pgid']
        or authority['leader']['pid'] != authority['leader']['sid']
        or authority['leader']['ppid'] != authority['supervisor']['pid']
        or authority.get('roots') != roots
        or set(authority.get('wrapper', {})) != {'path', 'sha256'}
        or re.fullmatch(r'[0-9a-f]{64}', authority['wrapper'].get('sha256', ''))
            is None
    ):
        raise SystemExit('process authority binding is invalid')
    authorities.append(authority)
    authority_entries.append({
        'path': str(path),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'launchId': authority['launchId'],
    })

reference_authorities = []
reference_entries = []
for path in reference_paths:
    raw = path.read_bytes()
    reference = json.loads(raw)
    if set(reference) != {
        'version', 'kind', 'exemptionId', 'ownerRoot', 'subject', 'executable',
        'program', 'argv', 'readiness', 'roots', 'allowedRootKeys',
    }:
        raise SystemExit('reference authority schema is invalid')
    executable = reference.get('executable')
    program = reference.get('program')
    readiness = reference.get('readiness')
    if (
        reference.get('version') != 1
        or reference.get('kind') != 'source-guard-reference-exemption'
        or re.fullmatch(r'[0-9a-f]{32}', reference.get('exemptionId', '')) is None
        or not valid_identity(reference.get('ownerRoot'))
        or not valid_identity(reference.get('subject'))
        or reference['ownerRoot'] != authorities[0]['ownerRoot']
        or reference['subject']['ppid'] != reference['ownerRoot']['pid']
        or reference.get('roots') != roots
        or not isinstance(reference.get('allowedRootKeys'), list)
        or not reference['allowedRootKeys']
        or reference['allowedRootKeys'] != sorted(set(reference['allowedRootKeys']))
        or not set(reference['allowedRootKeys']).issubset(set(root_names))
        or not isinstance(executable, dict)
        or set(executable) != {'path', 'sha256'}
        or not isinstance(program, dict)
        or set(program) != {'path', 'sha256'}
        or any(re.fullmatch(r'[0-9a-f]{64}', seal.get('sha256', '')) is None
               for seal in (executable, program))
        or any(pathlib.Path(seal.get('path', '')).resolve(strict=True)
               != pathlib.Path(seal['path']) for seal in (executable, program))
        or any(hashlib.sha256(pathlib.Path(seal['path']).read_bytes()).hexdigest()
               != seal['sha256'] for seal in (executable, program))
        or not isinstance(reference.get('argv'), list)
        or len(reference['argv']) < 5
        or reference['argv'][0] != executable['path']
        or reference['argv'][1:4] != ['-I', '-S', '-B']
        or reference['argv'][4] != program['path']
        or not isinstance(readiness, dict)
        or set(readiness) != {'path', 'sha256', 'nonce', 'stopPath', 'resultPath'}
        or re.fullmatch(r'[0-9a-f]{64}', readiness.get('sha256', '')) is None
        or re.fullmatch(r'[0-9a-f]{32}', readiness.get('nonce', '')) is None
        or hashlib.sha256(pathlib.Path(readiness['path']).read_bytes()).hexdigest()
            != readiness['sha256']
        or pathlib.Path(readiness['stopPath']).exists()
        or pathlib.Path(readiness['resultPath']).exists()
    ):
        raise SystemExit('reference authority binding is invalid')
    ready = json.loads(pathlib.Path(readiness['path']).read_text(encoding='utf-8'))
    if (ready.get('pid') != reference['subject']['pid']
            or ready.get('nonce') != readiness['nonce']):
        raise SystemExit('reference readiness binding is invalid')
    reference_authorities.append(reference)
    reference_entries.append({
        'path': str(path),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'exemptionId': reference['exemptionId'],
    })

process_fields = ('stoppedProcesses', 'termSentProcesses', 'killSentProcesses')
for field in process_fields:
    records = value.get(field)
    if (
        not isinstance(records, list)
        or not all(valid_record(record) for record in records)
        or [record['identity']['pid'] for record in records]
            != sorted({record['identity']['pid'] for record in records})
    ):
        raise SystemExit(f'process-scope record list is invalid: {field}')

inspection = value.get('referenceInspection')
lsof = inspection.get('lsof') if isinstance(inspection, dict) else None
if (
    set(value) != required
    or value.get('version') != 3
    or value.get('status') != 'quiescent'
    or value.get('marker') != (
        'TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT'
        if audit_only else 'TELLTALE_GATE_C_PROCESS_SCOPE'
    )
    or (audit_only and value.get('mode') != 'audit-only')
    or not valid_identity(value.get('ownerRoot'))
    or value.get('ownerRoot') != authorities[0]['ownerRoot']
    or value.get('roots') != roots
    or value.get('authorities') != authority_entries
    or value.get('referenceAuthorities') != reference_entries
    or value.get('authorizedSessions') != (
        [] if audit_only
        else sorted({authority['leader']['sid'] for authority in authorities})
    )
    or type(value.get('startedMonotonicNs')) is not int
    or type(value.get('endedMonotonicNs')) is not int
    or value['endedMonotonicNs'] < value['startedMonotonicNs']
    or value.get('remainingOwnedProcesses') != []
    or (audit_only and any(value.get(field) != [] for field in process_fields))
    or value.get('foreignProcesses') != []
    or value.get('inspectionLimitations') != []
    or not isinstance(inspection, dict)
    or set(inspection) != {'complete', 'lsof', 'fallbackProcesses'}
    or inspection.get('complete') is not True
    or not isinstance(inspection.get('fallbackProcesses'), list)
    or not all(valid_identity(item) for item in inspection['fallbackProcesses'])
    or [item['pid'] for item in inspection['fallbackProcesses']]
        != sorted({item['pid'] for item in inspection['fallbackProcesses']})
    or not isinstance(lsof, dict)
    or set(lsof) != {
        'path', 'sha256', 'device', 'inode', 'size', 'mtimeNs', 'mode', 'uid',
        'gid', 'nlink', 'codesignVerified', 'identifier', 'cdhash', 'authorities',
        'designatedRequirement',
    }
    or lsof.get('path') != '/usr/sbin/lsof'
    or re.fullmatch(r'[0-9a-f]{64}', lsof.get('sha256', '')) is None
    or any(type(lsof.get(key)) is not int
           for key in ('device', 'inode', 'size', 'mtimeNs', 'mode', 'uid', 'gid', 'nlink'))
    or lsof.get('mode') != 0o755
    or lsof.get('uid') != 0
    or lsof.get('nlink') != 1
    or lsof.get('codesignVerified') is not True
    or lsof.get('identifier') != 'com.apple.lsof'
    or re.fullmatch(r'[0-9a-f]{40}', lsof.get('cdhash', '')) is None
    or lsof.get('authorities') != [
        'macOS Software Signing', 'Apple Code Signing Certification Authority',
        'Apple Root CA',
    ]
    or lsof.get('designatedRequirement')
        != 'identifier "com.apple.lsof" and anchor apple'
):
    raise SystemExit('Gradle process-scope quiescence evidence is invalid')
reference_exempt = value.get('referenceExemptProcesses')
expected_subjects = {
    authority['exemptionId']: authority['subject']
    for authority in reference_authorities
}
if (
    not isinstance(reference_exempt, list)
    or len(reference_exempt) != len(reference_authorities)
    or [item.get('exemptionId') for item in reference_exempt]
        != sorted(expected_subjects, key=lambda item: expected_subjects[item]['pid'])
):
    raise SystemExit('process-scope reference exemptions are incomplete')
for item in reference_exempt:
    if (
        not isinstance(item, dict)
        or set(item) != {'exemptionId', 'process', 'reasons'}
        or item['exemptionId'] not in expected_subjects
        or not valid_record(item.get('process'))
        or item['process']['identity'] != expected_subjects[item['exemptionId']]
        or not isinstance(item.get('reasons'), list)
        or not item['reasons']
        or item['reasons'] != sorted(set(item['reasons']))
        or any(not isinstance(reason, str) for reason in item['reasons'])
    ):
        raise SystemExit('process-scope reference exemption is invalid')
print(f'process_scope_label={label}')
print('process_scope_quiescent=true')
PY
}

cleanup_isolated_gradle_home() {
  local gradle_root=${GRADLE_TEMP_PARENT:-} cleanup_exit scope_evidence
  [[ -n "$gradle_root" ]] || return 0
  (( GRADLE_FORENSIC_RETENTION_LATCH == 0 )) || return 75
  if [[ ! -e "$gradle_root" && ! -L "$gradle_root" ]]; then
    GRADLE_TEMP_PARENT=''
    unset GRADLE_USER_HOME
    return 0
  fi
  (( GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT += 1 ))
  scope_evidence="$EVIDENCE/gradle-process-scope-cleanup-${GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT}.json"
  if quiesce_gradle_process_scope cleanup "$scope_evidence"; then
    FINAL_PROCESS_SCOPE_EVIDENCE=$scope_evidence
  else
    cleanup_exit=$?
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return "$cleanup_exit"
  fi
  "$PYTHON" -I -S -B - "$gradle_root" <<'PY'
import os, pathlib, shutil, stat, sys
gradle_root = pathlib.Path(sys.argv[1])
status = os.lstat(gradle_root)
expected_parent = pathlib.Path('/tmp').resolve(strict=True)
if (
    gradle_root.parent != expected_parent
    or not gradle_root.name.startswith('telltale-gradle-home.')
    or stat.S_ISLNK(status.st_mode)
    or not stat.S_ISDIR(status.st_mode)
    or status.st_uid != os.getuid()
    or not shutil.rmtree.avoids_symlink_attacks
):
    raise SystemExit(f'refusing unsafe isolated Gradle cleanup: {gradle_root}')
shutil.rmtree(gradle_root)
PY
  cleanup_exit=$?
  if (( cleanup_exit != 0 )); then
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return "$cleanup_exit"
  fi
  GRADLE_TEMP_PARENT=''
  unset GRADLE_USER_HOME
}

cleanup_isolated_user_home() {
  local user_root=${ISOLATED_USER_TEMP_PARENT:-} cleanup_exit
  [[ -n "$user_root" ]] || return 0
  (( GRADLE_FORENSIC_RETENTION_LATCH == 0 )) || return 75
  if [[ ! -e "$user_root" && ! -L "$user_root" ]]; then
    ISOLATED_USER_TEMP_PARENT=''
    export HOME="$HOST_HOME"
    unset XDG_CONFIG_HOME ANDROID_USER_HOME
    return 0
  fi
  "$PYTHON" -I -S -B - "$user_root" <<'PY'
import os, pathlib, shutil, stat, sys
path = pathlib.Path(sys.argv[1])
status = os.lstat(path)
expected_parent = pathlib.Path('/tmp').resolve(strict=True)
if (
    path.parent != expected_parent
    or not path.name.startswith('telltale-gate-user-home.')
    or stat.S_ISLNK(status.st_mode)
    or not stat.S_ISDIR(status.st_mode)
    or status.st_uid != os.getuid()
    or not shutil.rmtree.avoids_symlink_attacks
):
    raise SystemExit(f'refusing unsafe isolated user-home cleanup: {path}')
shutil.rmtree(path)
PY
  cleanup_exit=$?
  if (( cleanup_exit != 0 )); then
    GRADLE_FORENSIC_RETENTION_LATCH=1
    return "$cleanup_exit"
  fi
  ISOLATED_USER_TEMP_PARENT=''
  export HOME="$HOST_HOME"
  unset XDG_CONFIG_HOME ANDROID_USER_HOME
}

cleanup_flutter_gradle_generated_state() {
  local requested_evidence=${1:-} cleanup_evidence cleanup_exit
  (( FLUTTER_GRADLE_GENERATED_DIRTY == 1 )) || return 0
  [[ -n ${SEALED_FLUTTER_ROOT:-} ]] || return 64
  if [[ -n "$requested_evidence" ]]; then
    cleanup_evidence=$requested_evidence
  else
    (( FLUTTER_GRADLE_GENERATED_CLEANUP_ATTEMPT += 1 ))
    cleanup_evidence="$EVIDENCE/flutter-gradle-generated-cleanup.exit-${FLUTTER_GRADLE_GENERATED_CLEANUP_ATTEMPT}.json"
  fi
  "$PYTHON" -I -S -B "$HERE/tree_manifest.py" \
    clean-flutter-gradle-generated-state \
    --root "$APP_ROOT" \
    --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
    --evidence "$cleanup_evidence"
  cleanup_exit=$?
  (( cleanup_exit == 0 )) || return "$cleanup_exit"
  FLUTTER_GRADLE_GENERATED_DIRTY=0
}

cleanup_reap_child() {
  local pid=$1 evidence=$2 label=$3 natural_ms=$4 term_ms=$5 kill_ms=$6
  local helper_exit key value version='' evidence_label='' evidence_pid=''
  local outcome='' clock_failure=''
  bounded_reap "$pid" "$evidence" "$label" \
    "$natural_ms" "$term_ms" "$kill_ms"
  helper_exit=$?
  [[ -f "$evidence" && ! -L "$evidence" && -O "$evidence" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      version) version=$value ;;
      label) evidence_label=$value ;;
      pid) evidence_pid=$value ;;
      outcome) outcome=$value ;;
      clock_failure) clock_failure=$value ;;
    esac
  done < "$evidence"
  [[ "$version" == 1 && "$evidence_label" == "$label" \
    && "$evidence_pid" == "$pid" && "$clock_failure" == false ]] \
    || return 1
  [[ "$outcome" == natural_exit || "$outcome" == terminated \
    || "$outcome" == killed ]] || return 1
  ! kill -0 "$pid" 2>/dev/null || return 1
  # A nonzero helper result may be the audited child exit status. The evidence
  # above, rather than the numeric status alone, distinguishes that case from
  # a clock/helper failure.
  : "$helper_exit"
  return 0
}

reap_bootstrap_guard_for_handoff() {
  local pid=$BOOTSTRAP_SOURCE_GUARD_PID reap_exit
  [[ "$pid" == <-> ]] || return 1
  bounded_reap "$pid" \
    "$EVIDENCE/bootstrap-source-tree-guard-exit.txt" \
    bootstrap-source-tree-guard 10000 2000 2000
  reap_exit=$?
  if ! kill -0 "$pid" 2>/dev/null; then
    BOOTSTRAP_SOURCE_GUARD_PID=''
  fi
  return "$reap_exit"
}

preserve_guard_event_ledger() {
  local live=${1:-} destination=${2:-} report=${3:-}
  [[ -n "$live" && -n "$destination" && -n "$report" \
    && -n ${ISOLATED_USER_TEMP_PARENT:-} ]] || return 0
  if [[ ! -e "$live" && ! -L "$live" \
    && ! -e "$destination" && ! -L "$destination" ]]; then
    return 0
  fi
  "$PYTHON" -I -S -B "$HERE/guard_ledger.py" \
    --live "$live" \
    --destination "$destination" \
    --temp-root "$ISOLATED_USER_TEMP_PARENT" \
    --evidence-root "$EVIDENCE" \
    > "$report"
}

bootstrap_exit() {
  local original_exit=$? cleanup_failed=0 retain_user_temp=0
  trap - EXIT
  set +e
  if [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]]; then
    if [[ -z "$BOOTSTRAP_SOURCE_GUARD_STOP" ]] \
      || ! touch "$BOOTSTRAP_SOURCE_GUARD_STOP"; then
      cleanup_failed=1
    fi
    cleanup_reap_child "$BOOTSTRAP_SOURCE_GUARD_PID" \
      "$EVIDENCE/bootstrap-source-tree-guard-exit.txt" \
      bootstrap-source-tree-guard 10000 2000 2000 \
      || cleanup_failed=1
    if kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null; then
      retain_user_temp=1
      cleanup_failed=1
    else
      BOOTSTRAP_SOURCE_GUARD_PID=''
    fi
  fi
  if (( retain_user_temp == 0 )); then
    preserve_guard_event_ledger \
      "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
      "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
      "$EVIDENCE/bootstrap-source-tree-guard-ledger-preservation.json" \
      || { cleanup_failed=1; retain_user_temp=1; }
  fi
  cleanup_isolated_gradle_home \
    || { cleanup_failed=1; retain_user_temp=1; }
  cleanup_flutter_gradle_generated_state \
    || cleanup_failed=1
  if (( retain_user_temp == 0 )); then
    cleanup_isolated_user_home \
      || { cleanup_failed=1; retain_user_temp=1; }
  fi
  (( cleanup_failed == 0 )) || original_exit=1
  exit "$original_exit"
}
trap bootstrap_exit EXIT

SEALED_FLUTTER_ROOT=$("$PYTHON" -I -S -B "$HERE/tree_manifest.py" flutter-root \
  --root "$APP_ROOT")
export TELLTALE_GATE_C_FLUTTER_ROOT="$SEALED_FLUTTER_ROOT"
assert_flutter_binding() {
  local configured_flutter_root
  configured_flutter_root=$("$PYTHON" -I -S -B "$HERE/tree_manifest.py" flutter-root \
    --root "$APP_ROOT") \
    || die "android/local.properties Flutter SDK could not be resolved"
  [[ ${configured_flutter_root:A} == ${SEALED_FLUTTER_ROOT:A} ]] \
    || die "android/local.properties Flutter SDK changed during the live rig"
  [[ ${FLUTTER:A} == ${SEALED_FLUTTER_ROOT:A}/bin/flutter ]] \
    || die "FLUTTER override does not match the sealed android/local.properties SDK"
  [[ ${DART:A} == ${SEALED_FLUTTER_ROOT:A}/bin/dart ]] \
    || die "DART override does not match the sealed android/local.properties SDK"
}
assert_flutter_binding
[[ -x "$FLUTTER" ]] || die "pinned Flutter not executable: $FLUTTER"
[[ -x "$DART" ]] || die "pinned Dart not executable: $DART"
[[ -x "$SEALED_SDK_EXEC" ]] || die "sealed SDK executor is not executable"
[[ -x "$ANDROID_SDK_SANDBOX_EXEC" && ! -L "$ANDROID_SDK_SANDBOX_EXEC" ]] \
  || die "Android SDK sandbox executor is missing or unsafe"
for sandbox_component in \
  "$ANDROID_SDK_SANDBOX_PREFLIGHT" \
  "$ANDROID_SDK_SANDBOX_PROFILE" \
  "$ANDROID_SDK_SANDBOX_PROBE" \
  "$PROCESS_SCOPE_HELPER" \
  "$SCOPED_COMMAND"; do
  [[ -f "$sandbox_component" && ! -L "$sandbox_component" ]] \
    || die "Android SDK sandbox component is missing or unsafe: $sandbox_component"
done
CACHED_DART="$SEALED_FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
FLUTTER_TOOLS_SNAPSHOT="$SEALED_FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
[[ -x "$CACHED_DART" ]] || die "sealed cached Dart is not executable"
[[ -f "$FLUTTER_TOOLS_SNAPSHOT" && ! -L "$FLUTTER_TOOLS_SNAPSHOT" ]] \
  || die "sealed Flutter tools snapshot is missing or unsafe"
cd "$APP_ROOT"
sealed_flutter() {
  local label=$1
  shift
  run_scoped_sandbox_command "$label" "$APP_ROOT" \
    "$ANDROID_SDK_SANDBOX_EXEC" -- \
    "$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter --no-version-check "$@"
}

sealed_dart() {
  local label=$1
  shift
  run_scoped_sandbox_command "$label" "$APP_ROOT" \
    "$ANDROID_SDK_SANDBOX_EXEC" -- \
    "$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" dart "$@"
}

SEALED_ANDROID_SDK_ROOT=$("$PYTHON" -I -S -B "$HERE/tree_manifest.py" android-sdk-root \
  --root "$APP_ROOT")
SEALED_PUB_CACHE=$("$PYTHON" -I -S -B - "$HOST_HOME/.pub-cache" <<'PY'
import os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
current = pathlib.Path(path.anchor)
for part in path.parts[1:]:
    current /= part
    if stat.S_ISLNK(os.lstat(current).st_mode):
        raise SystemExit(f'symlinked Dart pub cache path: {current}')
resolved = path.resolve(strict=True)
if not resolved.is_dir():
    raise SystemExit(f'Dart pub cache is not a directory: {resolved}')
print(resolved)
PY
)
export PUB_CACHE="$SEALED_PUB_CACHE"
BOOTSTRAP_FLUTTER_BINDINGS="$EVIDENCE/flutter-config-bindings.json"
HOST_FLUTTER_SETTINGS="$HOST_HOME/.config/flutter/settings"
"$PYTHON" -I -S -B - "$HOST_FLUTTER_SETTINGS" \
  "$SEALED_ANDROID_SDK_ROOT" "$BOOTSTRAP_FLUTTER_BINDINGS" <<'PY'
import json, os, pathlib, stat, sys

def safe_directory(raw, label):
    if (
        not isinstance(raw, str)
        or not raw
        or any(ord(character) < 32 or ord(character) == 127 for character in raw)
    ):
        raise SystemExit(f"invalid Flutter config path: {label}")
    path = pathlib.Path(raw)
    if not path.is_absolute():
        raise SystemExit(f"non-absolute Flutter config path: {label}")
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise SystemExit(f"symlinked Flutter config path: {label}")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise SystemExit(f"Flutter config path is not a directory: {label}")
    return str(resolved)

settings_path = pathlib.Path(sys.argv[1])
current = pathlib.Path(settings_path.anchor)
for part in settings_path.parts[1:]:
    current /= part
    if stat.S_ISLNK(os.lstat(current).st_mode):
        raise SystemExit(f"symlinked host Flutter settings path: {current}")
settings_status = os.lstat(settings_path)
if (
    not stat.S_ISREG(settings_status.st_mode)
    or settings_status.st_nlink != 1
    or settings_status.st_uid != os.getuid()
    or settings_status.st_mode & 0o022
):
    raise SystemExit("host Flutter settings metadata is unsafe")
value = json.loads(settings_path.read_text(encoding="utf-8"))
if not isinstance(value, dict):
    raise SystemExit("host Flutter settings did not contain an object")
if "android-ndk" in value:
    raise SystemExit("global Flutter android-ndk override is not allowed for Gate C")
sealed_android_sdk = safe_directory(sys.argv[2], "sealed android-sdk")
configured_android_sdk = value.get("android-sdk")
if configured_android_sdk is not None:
    configured_android_sdk = safe_directory(
        configured_android_sdk,
        "configured android-sdk",
    )
    if configured_android_sdk != sealed_android_sdk:
        raise SystemExit(
            "host Flutter Android SDK does not match android/local.properties"
        )
redacted = {
    "version": 1,
    "androidSdk": sealed_android_sdk,
    "jdkRoot": safe_directory(value.get("jdk-dir"), "jdk-dir"),
    "globalAndroidNdkPresent": False,
    "hostSettingsSha256": __import__("hashlib").sha256(
        settings_path.read_bytes()
    ).hexdigest(),
}
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(redacted, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
CONFIG_ANDROID_SDK=$("$PYTHON" -I -S -B -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["androidSdk"])' \
  "$BOOTSTRAP_FLUTTER_BINDINGS")
SEALED_JDK_ROOT=$("$PYTHON" -I -S -B -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["jdkRoot"])' \
  "$BOOTSTRAP_FLUTTER_BINDINGS")
export TELLTALE_GATE_C_JDK_ROOT="$SEALED_JDK_ROOT"
[[ ${CONFIG_ANDROID_SDK:A} == ${SEALED_ANDROID_SDK_ROOT:A} ]] \
  || die "Flutter config Android SDK does not match android/local.properties"

ISOLATED_USER_TEMP_PARENT=$(mktemp -d /tmp/telltale-gate-user-home.XXXXXX)
ISOLATED_USER_TEMP_PARENT=${ISOLATED_USER_TEMP_PARENT:A}
HOME="$ISOLATED_USER_TEMP_PARENT/home"
XDG_CONFIG_HOME="$ISOLATED_USER_TEMP_PARENT/xdg-config"
ANDROID_USER_HOME="$ISOLATED_USER_TEMP_PARENT/android-user-home"
ANDROID_SDK_SANDBOX_RUN_TEMP="$ISOLATED_USER_TEMP_PARENT/sandbox-run"
KOTLIN_PROJECT_PERSISTENT_DIR="$ANDROID_SDK_SANDBOX_RUN_TEMP/kotlin-project-persistent"
KOTLIN_DAEMON_RUN_FILES_DIR="$ANDROID_SDK_SANDBOX_RUN_TEMP/kotlin-daemon"
mkdir -p "$HOME" "$ANDROID_USER_HOME" \
  "$ANDROID_SDK_SANDBOX_RUN_TEMP" "$KOTLIN_PROJECT_PERSISTENT_DIR" \
  "$KOTLIN_DAEMON_RUN_FILES_DIR"
chmod 700 "$ISOLATED_USER_TEMP_PARENT" "$HOME" "$ANDROID_USER_HOME" \
  "$ANDROID_SDK_SANDBOX_RUN_TEMP" \
  "$KOTLIN_PROJECT_PERSISTENT_DIR" "$KOTLIN_DAEMON_RUN_FILES_DIR"
export HOME XDG_CONFIG_HOME ANDROID_USER_HOME
ISOLATED_FLUTTER_SETTINGS="$XDG_CONFIG_HOME/settings"
"$PYTHON" -I -S -B - "$ISOLATED_FLUTTER_SETTINGS" \
  "$SEALED_ANDROID_SDK_ROOT" "$SEALED_JDK_ROOT" <<'PY'
import json, os, pathlib, sys

path = pathlib.Path(sys.argv[1])
path.parent.mkdir(mode=0o700)
descriptor = os.open(
    path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
    0o600,
)
try:
    payload = json.dumps(
        {"android-sdk": sys.argv[2], "jdk-dir": sys.argv[3]},
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n"
    os.write(descriptor, payload.encode("utf-8"))
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY

assert_isolated_flutter_config() {
  "$PYTHON" -I -S -B - "$ISOLATED_FLUTTER_SETTINGS" "$SEALED_ANDROID_SDK_ROOT" \
    "$SEALED_JDK_ROOT" <<'PY'
import json, os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
status = os.lstat(path)
if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
    raise SystemExit('isolated Flutter settings is not a single regular file')
value = json.loads(path.read_text(encoding='utf-8'))
expected = {'android-sdk': sys.argv[2], 'jdk-dir': sys.argv[3]}
if value != expected:
    raise SystemExit('isolated Flutter settings changed or contains unexpected keys')
print('isolated_flutter_settings_verified=true')
PY
}
assert_isolated_flutter_config > "$EVIDENCE/flutter-config-isolation-validated.txt"
shasum -a 256 "$ISOLATED_FLUTTER_SETTINGS" \
  > "$EVIDENCE/flutter-settings.pre.sha256"

EXPECTED_ADB="$SEALED_ANDROID_SDK_ROOT/platform-tools/adb"
[[ -x "$EXPECTED_ADB" && ! -L "$EXPECTED_ADB" ]] \
  || die "Android SDK platform-tools adb is missing or unsafe"
ADB_COMMAND=$(command -v "$ADB" 2>/dev/null || true)
[[ -n "$ADB_COMMAND" && ${ADB_COMMAND:A} == ${EXPECTED_ADB:A} ]] \
  || die "ADB override does not match the sealed Android SDK platform-tools"
ADB=${ADB_COMMAND:A}

export JAVA_HOME="$SEALED_JDK_ROOT"
export ANDROID_HOME="$SEALED_ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT="$SEALED_ANDROID_SDK_ROOT"

# Package-owned native build directories are generated state, not source.
# Remove every approved dependency's pre-existing .cxx tree before sealing so
# Ninja cannot relink an old or planted object into the authoritative APK.
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" \
  clean-external-native-caches \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --evidence "$EVIDENCE/external-native-cache-cleanup.pre.json"

# Flutter's Gradle plugin is an included build. Purge its project-local
# generated state before sealing so no old cache, class, or plugin JAR can be
# consumed. The sandbox later permits writes only to these exact three roots.
FLUTTER_GRADLE_GENERATED_DIRTY=1
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" \
  clean-flutter-gradle-generated-state \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --evidence "$EVIDENCE/flutter-gradle-generated-cleanup.pre.json"

# Remove approved generated inputs before sealing. Keeping this outside the
# bootstrap watcher prevents an existing build backlog from becoming guard
# traffic while preserving the subsequent live integrity barrier.
"$PYTHON" -I -S -B - "$APP_ROOT" "$EVIDENCE/generated-input-cleanup.json" <<'PY'
import json, os, pathlib, shutil, stat, sys

def existing_path_without_symlinks(path):
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        status = os.lstat(current)
        if stat.S_ISLNK(status.st_mode):
            raise SystemExit(f'refusing symlinked generated-input cleanup path: {current}')
    return path.resolve(strict=True)

root = existing_path_without_symlinks(pathlib.Path(sys.argv[1]))
if not root.is_dir() or not shutil.rmtree.avoids_symlink_attacks:
    raise SystemExit(f'refusing unsafe generated-input cleanup root: {root}')
checked = [
    'build',
    'android/.gradle',
    '.dart_tool/flutter_build',
    '.dart_tool/hooks_runner',
    '.dart_tool/test',
]
removed = []
for relative in checked:
    path = root / relative
    current = root
    missing = False
    for part in pathlib.PurePosixPath(relative).parts:
        current /= part
        try:
            status = os.lstat(current)
        except FileNotFoundError:
            missing = True
            break
        if stat.S_ISLNK(status.st_mode):
            raise SystemExit(f'refusing symlinked generated-input cleanup path: {current}')
        if current != path and not stat.S_ISDIR(status.st_mode):
            raise SystemExit(f'refusing non-directory cleanup ancestor: {current}')
    if missing:
        continue
    status = os.lstat(path)
    resolved = path.resolve(strict=True)
    if (
        stat.S_ISLNK(status.st_mode)
        or not stat.S_ISDIR(status.st_mode)
        or not resolved.is_relative_to(root)
    ):
        raise SystemExit(f'refusing unsafe generated-input cleanup: {path}')
    shutil.rmtree(resolved)
    removed.append(relative)
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(
        {'version': 1, 'checked': checked, 'removed': removed},
        sort_keys=True,
    ) + '\n',
    encoding='utf-8',
)
PY

# Establish a live integrity barrier before the first JDK, Gradle, Flutter, or
# Dart SDK executable runs.  The later authoritative guard overlaps this one
# and adds the freshly generated debug key plus extracted Gradle distribution.
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" write \
  --root "$APP_ROOT" \
  --manifest "$EVIDENCE/tested-files.bootstrap.sha256" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT"
BOOTSTRAP_SOURCE_GUARD_STOP="$EVIDENCE/bootstrap-source-tree-guard.stop"
BOOTSTRAP_SOURCE_GUARD_READY="$EVIDENCE/bootstrap-source-tree-guard-ready.json"
BOOTSTRAP_SOURCE_GUARD_EVENTS="$EVIDENCE/bootstrap-source-tree-guard-events.jsonl"
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE="$ISOLATED_USER_TEMP_PARENT/bootstrap-source-tree-guard-events.jsonl"
BOOTSTRAP_SOURCE_GUARD_RESULT="$EVIDENCE/bootstrap-source-tree-guard-result.json"
BOOTSTRAP_SOURCE_GUARD_BASELINE_SIDECAR="$EVIDENCE/bootstrap-source-tree-guard-baseline.json"
BOOTSTRAP_SOURCE_GUARD_LOG="$EVIDENCE/bootstrap-source-tree-guard.log"
for guard_path in \
  "$BOOTSTRAP_SOURCE_GUARD_STOP" "$BOOTSTRAP_SOURCE_GUARD_READY" \
  "$BOOTSTRAP_SOURCE_GUARD_EVENTS" "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
  "$BOOTSTRAP_SOURCE_GUARD_RESULT" "$BOOTSTRAP_SOURCE_GUARD_BASELINE_SIDECAR" \
  "$BOOTSTRAP_SOURCE_GUARD_LOG"; do
  [[ ! -e "$guard_path" && ! -L "$guard_path" ]] \
    || die "stale bootstrap source-tree guard evidence exists: $guard_path"
done
BOOTSTRAP_SOURCE_GUARD_NONCE=$(
  "$PYTHON" -I -S -B -c 'import secrets; print(secrets.token_hex(16))'
)
BOOTSTRAP_SOURCE_GUARD_LAUNCHED_EPOCH_US=$(
  "$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)'
)
"$PYTHON" -I -S -B "$HERE/source_tree_guard.py" \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --toolchain-root "$SEALED_ANDROID_SDK_ROOT" \
  --toolchain-root "$SEALED_JDK_ROOT" \
  --toolchain-root "$ISOLATED_FLUTTER_SETTINGS" \
  --toolchain-root "$PYTHON_RUNTIME_ROOT" \
  --backend darwin-fsevents \
  --stop-file "$BOOTSTRAP_SOURCE_GUARD_STOP" \
  --ready-file "$BOOTSTRAP_SOURCE_GUARD_READY" \
  --events-file "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
  --result-file "$BOOTSTRAP_SOURCE_GUARD_RESULT" \
  --baseline-manifest "$EVIDENCE/tested-files.bootstrap.sha256" \
  --baseline-sidecar "$BOOTSTRAP_SOURCE_GUARD_BASELINE_SIDECAR" \
  --nonce "$BOOTSTRAP_SOURCE_GUARD_NONCE" \
  > "$BOOTSTRAP_SOURCE_GUARD_LOG" 2>&1 &
BOOTSTRAP_SOURCE_GUARD_PID=$!
if wait_for_live_guard_ready "$BOOTSTRAP_SOURCE_GUARD_PID" "$BOOTSTRAP_SOURCE_GUARD_READY" \
  "$SOURCE_GUARD_READY_TIMEOUT_MS"; then
  :
else
  ready_wait_status=$?
  case $ready_wait_status in
    1) die "bootstrap source-tree guard did not become ready" ;;
    2) die "bootstrap source-tree guard exited before ready" ;;
    3) die "bootstrap source-tree guard readiness evidence is unsafe" ;;
    127) die "bootstrap source-tree guard readiness clock failed" ;;
    *) die "bootstrap source-tree guard readiness wait failed" ;;
  esac
fi
"$PYTHON" -I -S -B - "$BOOTSTRAP_SOURCE_GUARD_READY" \
  "$BOOTSTRAP_SOURCE_GUARD_NONCE" "$BOOTSTRAP_SOURCE_GUARD_PID" \
  "$BOOTSTRAP_SOURCE_GUARD_LAUNCHED_EPOCH_US" \
  "$EVIDENCE/tested-files.bootstrap.sha256" \
  "$BOOTSTRAP_SOURCE_GUARD_BASELINE_SIDECAR" \
  "$SEALED_ANDROID_SDK_ROOT" "$SEALED_JDK_ROOT" \
  "$ISOLATED_FLUTTER_SETTINGS" "$PYTHON_RUNTIME_ROOT" \
  > "$EVIDENCE/bootstrap-source-tree-guard-ready-validated.txt" <<'PY'
import hashlib, json, os, pathlib, stat, sys, time

path, nonce, pid_text, launched_text, baseline_text, sidecar_text, *required_roots = sys.argv[1:]
value = json.load(open(path, encoding='utf-8'))
POLICY = 'sealed-manifest-pure-item-cloned-v2'
SIDECAR_KEYS = {
    'version', 'policy', 'manifestPath', 'manifestSha256',
    'manifestEntryCount', 'uniqueRegularFileCount',
    'uniqueRegularFileBytes', 'totalXattrBytes',
    'namespaceEntryCounts', 'eventScopeFileCounts', 'records',
}
ATTESTATION_FIELDS = (
    'baselineManifestPath', 'baselineManifestSha256',
    'baselineSidecarPath', 'baselineSidecarSha256', 'baselineSidecarBytes',
    'baselineManifestEntryCount', 'baselineUniqueRegularFileCount',
    'baselineUniqueRegularFileBytes', 'baselineTotalXattrBytes',
    'baselineNamespaceEntryCounts', 'baselineEventScopeFileCounts',
)
FINGERPRINT_FIELDS = {
    'sha256', 'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size',
    'mtimeNs', 'ctimeNs', 'birthtimeNs', 'fileFlags', 'xattrs',
}
FINGERPRINT_INTEGER_FIELDS = (
    'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size', 'mtimeNs', 'ctimeNs',
)
NAMESPACES = {'local', 'package', 'flutterToolPackage', 'flutterToolchain'}
EVENT_SCOPES = {'exact-file', 'local-directory', 'external-package', 'toolchain'}
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_SIDECAR_BYTES = 64 * 1024 * 1024

def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)

def valid_fingerprint(fingerprint):
    if not isinstance(fingerprint, dict) or set(fingerprint) != FINGERPRINT_FIELDS:
        return False
    if not valid_sha256(fingerprint.get('sha256')):
        return False
    if any(type(fingerprint.get(field)) is not int or fingerprint[field] < 0 for field in FINGERPRINT_INTEGER_FIELDS):
        return False
    if (
        fingerprint['inode'] < 1
        or fingerprint['mode'] & 0o170000 != 0o100000
        or fingerprint['mode'] & 0o002
        or (
            fingerprint['mode'] & 0o020
            and fingerprint['gid'] in {os.getegid(), *os.getgroups()}
        )
        or fingerprint['linkCount'] != 1
        or fingerprint['uid'] != os.getuid()
    ):
        return False
    for field in ('birthtimeNs', 'fileFlags'):
        field_value = fingerprint.get(field)
        if field_value is not None and (type(field_value) is not int or field_value < 0):
            return False
    xattrs = fingerprint.get('xattrs')
    if not isinstance(xattrs, list):
        return False
    names = []
    for xattr in xattrs:
        name = xattr.get('name') if isinstance(xattr, dict) else None
        suffix = name[4:] if isinstance(name, str) and name.startswith('hex:') else ''
        if (
            not isinstance(xattr, dict) or set(xattr) != {'name', 'bytes', 'sha256'}
            or not suffix or len(suffix) % 2 or any(c not in '0123456789abcdef' for c in suffix)
            or type(xattr.get('bytes')) is not int or xattr['bytes'] < 0
            or not valid_sha256(xattr.get('sha256'))
        ):
            return False
        names.append(name)
    return names == sorted(names) and len(names) == len(set(names))

def safe_regular_bytes(path_text, maximum, label):
    supplied = pathlib.Path(path_text)
    if not supplied.is_absolute():
        raise SystemExit(f'{label} path is not absolute')
    try:
        canonical = supplied.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f'{label} path is unsafe: {error}') from error
    if supplied != canonical:
        raise SystemExit(f'{label} path is not canonical')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise SystemExit(f'{label} could not be opened safely: {error}') from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid != os.getuid() or before.st_mode & 0o022
            or before.st_size < 1 or before.st_size > maximum
        ):
            raise SystemExit(f'{label} metadata is unsafe')
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f'{label} exceeds byte bound')
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise SystemExit(f'{label} changed while reading')
    finally:
        os.close(descriptor)
    return canonical, b''.join(chunks)

def namespace_for(logical_id):
    if logical_id.startswith('@package/'):
        return 'package'
    if logical_id.startswith('@flutter-tool-package/'):
        return 'flutterToolPackage'
    if logical_id.startswith('@toolchain/'):
        return 'flutterToolchain'
    if logical_id.startswith('@'):
        raise SystemExit('baseline manifest namespace is unknown')
    return 'local'

def load_baseline(manifest_text, sidecar_text):
    manifest, manifest_bytes = safe_regular_bytes(manifest_text, MAX_MANIFEST_BYTES, 'baseline manifest')
    try:
        manifest_source = manifest_bytes.decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise SystemExit('baseline manifest is not strict UTF-8') from error
    manifest_entries = {}
    manifest_order = []
    for number, line in enumerate(manifest_source.splitlines(), 1):
        if len(line) < 67 or line[64:66] != '  ' or not valid_sha256(line[:64]):
            raise SystemExit(f'baseline manifest line {number} is invalid')
        logical_id = line[66:]
        pure = pathlib.PurePosixPath(logical_id)
        if (
            not logical_id or pure.is_absolute() or '..' in pure.parts
            or any(ord(c) < 32 or ord(c) == 127 for c in logical_id)
            or logical_id in manifest_entries
        ):
            raise SystemExit('baseline manifest logical ID is unsafe or duplicate')
        manifest_entries[logical_id] = (line[:64], namespace_for(logical_id))
        manifest_order.append(logical_id)
        if len(manifest_entries) > 50_000:
            raise SystemExit('baseline manifest exceeds entry bound')
    if not manifest_entries or manifest_order != sorted(manifest_order):
        raise SystemExit('baseline manifest is empty or non-canonical')
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    sidecar, sidecar_bytes = safe_regular_bytes(sidecar_text, MAX_SIDECAR_BYTES, 'baseline sidecar')
    try:
        payload = json.loads(sidecar_bytes.decode('utf-8', errors='strict'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit('baseline sidecar is invalid JSON') from error
    canonical_sidecar = (json.dumps(payload, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if sidecar_bytes != canonical_sidecar or not isinstance(payload, dict) or set(payload) != SIDECAR_KEYS:
        raise SystemExit('baseline sidecar is not canonical schema v1')
    if (
        type(payload.get('version')) is not int or payload['version'] != 1
        or payload.get('policy') != POLICY
        or payload.get('manifestPath') != str(manifest)
        or payload.get('manifestSha256') != manifest_sha
    ):
        raise SystemExit('baseline sidecar identity is invalid')
    records = payload.get('records')
    if not isinstance(records, list) or not records:
        raise SystemExit('baseline sidecar records are empty')
    records_by_path = {}
    seen_logical_ids = set()
    namespace_counts = {}
    scope_counts = {}
    unique_bytes = 0
    xattr_bytes = 0
    record_paths = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {'canonicalPath', 'eventScope', 'manifestEntries', 'fingerprint'}:
            raise SystemExit('baseline sidecar record schema is invalid')
        path_text = record.get('canonicalPath')
        try:
            canonical_path = pathlib.Path(path_text).resolve(strict=True) if isinstance(path_text, str) else None
        except (OSError, RuntimeError) as error:
            raise SystemExit('baseline sidecar canonical path is invalid') from error
        if canonical_path is None or not canonical_path.is_file() or str(canonical_path) != path_text or path_text in records_by_path:
            raise SystemExit('baseline sidecar canonical path is invalid or duplicate')
        scope = record.get('eventScope')
        entries = record.get('manifestEntries')
        fingerprint = record.get('fingerprint')
        if scope not in EVENT_SCOPES or not isinstance(entries, list) or not entries or not valid_fingerprint(fingerprint):
            raise SystemExit('baseline sidecar record content is invalid')
        logical_ids = []
        alias_digests = set()
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {'logicalId', 'namespace', 'sha256'}:
                raise SystemExit('baseline sidecar manifest entry schema is invalid')
            logical_id = entry.get('logicalId')
            expected = manifest_entries.get(logical_id)
            if (
                expected is None or logical_id in seen_logical_ids
                or entry.get('namespace') not in NAMESPACES
                or (entry.get('sha256'), entry.get('namespace')) != expected
            ):
                raise SystemExit('baseline sidecar manifest coverage is invalid')
            seen_logical_ids.add(logical_id)
            logical_ids.append(logical_id)
            alias_digests.add(entry['sha256'])
            namespace_counts[entry['namespace']] = namespace_counts.get(entry['namespace'], 0) + 1
        if logical_ids != sorted(logical_ids) or len(alias_digests) != 1 or fingerprint['sha256'] not in alias_digests:
            raise SystemExit('baseline sidecar aliases or fingerprint digest are invalid')
        records_by_path[path_text] = record
        record_paths.append(path_text)
        unique_bytes += fingerprint['size']
        xattr_bytes += sum(item['bytes'] for item in fingerprint['xattrs'])
        if unique_bytes > 4 * 1024 * 1024 * 1024 or xattr_bytes > 64 * 1024 * 1024:
            raise SystemExit('baseline sidecar aggregate bytes exceed bounds')
        scope_counts[scope] = scope_counts.get(scope, 0) + 1
    if record_paths != sorted(record_paths) or seen_logical_ids != set(manifest_entries):
        raise SystemExit('baseline sidecar record order or manifest coverage is invalid')
    expected_counts = {
        'manifestEntryCount': len(manifest_entries),
        'uniqueRegularFileCount': len(records),
        'uniqueRegularFileBytes': unique_bytes,
        'totalXattrBytes': xattr_bytes,
        'namespaceEntryCounts': dict(sorted(namespace_counts.items())),
        'eventScopeFileCounts': dict(sorted(scope_counts.items())),
    }
    for field, expected in expected_counts.items():
        actual = payload.get(field)
        if type(actual) is not type(expected) or actual != expected:
            raise SystemExit(f'baseline sidecar {field} is invalid')
    attestation = {
        'baselineManifestPath': str(manifest),
        'baselineManifestSha256': manifest_sha,
        'baselineSidecarPath': str(sidecar),
        'baselineSidecarSha256': hashlib.sha256(sidecar_bytes).hexdigest(),
        'baselineSidecarBytes': len(sidecar_bytes),
        'baselineManifestEntryCount': expected_counts['manifestEntryCount'],
        'baselineUniqueRegularFileCount': expected_counts['uniqueRegularFileCount'],
        'baselineUniqueRegularFileBytes': expected_counts['uniqueRegularFileBytes'],
        'baselineTotalXattrBytes': expected_counts['totalXattrBytes'],
        'baselineNamespaceEntryCounts': expected_counts['namespaceEntryCounts'],
        'baselineEventScopeFileCounts': expected_counts['eventScopeFileCounts'],
    }
    return records_by_path, attestation

def require_attestation(value, expected, label):
    if not isinstance(value, dict):
        raise SystemExit(f'{label} is not an object')
    for field in ATTESTATION_FIELDS:
        actual = value.get(field)
        wanted = expected[field]
        if type(actual) is not type(wanted) or actual != wanted:
            raise SystemExit(f'{label} {field} does not match sealed baseline')

records_by_path, attestation = load_baseline(baseline_text, sidecar_text)
require_attestation(value, attestation, 'source-tree guard readiness')
watch_paths = value.get('watchPaths')
native_roots = value.get('nativeFSEventsWatchRoots')
required = {str(pathlib.Path(item).resolve(strict=True)) for item in required_roots}
native_root_paths = (
    [pathlib.Path(item) for item in native_roots]
    if isinstance(native_roots, list) and all(isinstance(item, str) for item in native_roots)
    else []
)
sidecar_path = pathlib.Path(attestation['baselineSidecarPath'])
if (
    value.get('version') != 3
    or value.get('nonce') != nonce
    or value.get('watcherBackend') != 'darwin-fsevents'
    or value.get('pid') != int(pid_text)
    or type(value.get('startedEpochUs')) is not int
    or value['startedEpochUs'] < int(launched_text)
    or value['startedEpochUs'] > time.time_ns() // 1000
    or value.get('canaryCreatedObserved') is not True
    or value.get('canaryRemovedObserved') is not True
    or type(value.get('canaryWriteAttemptCount')) is not int
    or value['canaryWriteAttemptCount'] < 1
    or type(value.get('canaryDeleteAttemptCount')) is not int
    or value['canaryDeleteAttemptCount'] < 1
    or type(value.get('watcherPid')) is not int or value['watcherPid'] <= 0
    or type(value.get('suppressedInternalSinkEventCount')) is not int
    or value['suppressedInternalSinkEventCount'] < 0
    or value.get('cloneReconciliationPolicy') != POLICY
    or not isinstance(watch_paths, list) or not watch_paths
    or not required.issubset(set(watch_paths))
    or not native_root_paths
    or any(not root.is_dir() or root.resolve(strict=True) != root for root in native_root_paths)
    or any(not any(watched == root or watched.is_relative_to(root) for root in native_root_paths) for watched in map(pathlib.Path, watch_paths))
    or any(
        sidecar_path == watched or sidecar_path.is_relative_to(watched)
        for watched in map(pathlib.Path, watch_paths)
    )
):
    raise SystemExit('source-tree guard readiness identity/canary/baseline proof failed')
print(f"guard_pid={value['pid']}")
print(f"watcher_pid={value['watcherPid']}")
print(f"baseline_manifest_entries={attestation['baselineManifestEntryCount']}")
print(f"baseline_unique_files={len(records_by_path)}")
print('bootstrap_guard_ready_verified=true')
PY
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" verify \
  --root "$APP_ROOT" \
  --manifest "$EVIDENCE/tested-files.bootstrap.sha256" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  || die "tested tree changed while establishing the bootstrap guard"

assert_bootstrap_guard_live() {
  [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]] \
    || die "bootstrap source-tree guard PID is unavailable"
  kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null \
    || die "bootstrap source-tree guard exited before handoff"
  [[ ! -e "$BOOTSTRAP_SOURCE_GUARD_STOP" ]] \
    || die "bootstrap source-tree guard stop appeared before handoff"
  [[ -f "$BOOTSTRAP_SOURCE_GUARD_READY" \
    && ! -e "$BOOTSTRAP_SOURCE_GUARD_RESULT" ]] \
    || die "bootstrap source-tree guard evidence changed before handoff"
}
assert_bootstrap_guard_live

create_source_guard_reference_authority() {
  local label=$1 subject_pid=$2 readiness=$3 nonce=$4 stop_path=$5 result_path=$6
  local output="$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR/$label.reference-authority.json"
  local exemption_id program_sha
  [[ -n "$label" && "$label" != *[^a-z0-9-]* \
    && "$subject_pid" == <-> && "$subject_pid" -gt 1 ]] || return 64
  [[ ! -e "$output" && ! -L "$output" ]] || return 65
  exemption_id=$("$PYTHON" -I -S -B -c 'import secrets; print(secrets.token_hex(16))')
  program_sha=$(shasum -a 256 "$HERE/source_tree_guard.py" | awk '{print $1}')
  "$PYTHON" -I -S -B "$PROCESS_SCOPE_HELPER" create-reference \
    --subject-pid "$subject_pid" \
    --owner-root-pid "$GATE_OWNER_ROOT_PID" \
    --exemption-id "$exemption_id" \
    --program "$HERE/source_tree_guard.py" \
    --program-sha256 "$program_sha" \
    --readiness "$readiness" \
    --nonce "$nonce" \
    --stop "$stop_path" \
    --result "$result_path" \
    --gradle-user-home "$GRADLE_USER_HOME" \
    --isolated-user-root "$ISOLATED_USER_TEMP_PARENT" \
    --home "$HOME" \
    --sandbox-run-temp "$ANDROID_SDK_SANDBOX_RUN_TEMP" \
    --kotlin-project-persistent-dir "$KOTLIN_PROJECT_PERSISTENT_DIR" \
    --kotlin-daemon-run-files-dir "$KOTLIN_DAEMON_RUN_FILES_DIR" \
    --output "$output" || return $?
  [[ -f "$output" && ! -L "$output" && -O "$output" \
    && $(stat -f '%Lp' "$output") == 600 ]] || return 66
  print -r -- "$output"
}

build_scope_reference_args() {
  local option=${1:---reference-authority}
  SCOPE_REFERENCE_ARGS=()
  if [[ ${BOOTSTRAP_SOURCE_GUARD_PID:-} == <-> \
    && -n ${BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY:-} \
    && -f "$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY" \
    && ! -L "$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY" ]] \
    && kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null; then
    "$PYTHON" -I -S -B "$PROCESS_SCOPE_HELPER" verify-reference \
      --authority "$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY" \
      --owner-root-pid "$GATE_OWNER_ROOT_PID" || return 1
    SCOPE_REFERENCE_ARGS+=("$option" "$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY")
  fi
  if [[ ${SOURCE_GUARD_PID:-} == <-> \
    && -n ${SOURCE_GUARD_REFERENCE_AUTHORITY:-} \
    && -f "$SOURCE_GUARD_REFERENCE_AUTHORITY" \
    && ! -L "$SOURCE_GUARD_REFERENCE_AUTHORITY" ]] \
    && kill -0 "$SOURCE_GUARD_PID" 2>/dev/null; then
    "$PYTHON" -I -S -B "$PROCESS_SCOPE_HELPER" verify-reference \
      --authority "$SOURCE_GUARD_REFERENCE_AUTHORITY" \
      --owner-root-pid "$GATE_OWNER_ROOT_PID" || return 1
    SCOPE_REFERENCE_ARGS+=("$option" "$SOURCE_GUARD_REFERENCE_AUTHORITY")
  fi
  (( ${#SCOPE_REFERENCE_ARGS} > 0 )) || return 1
}

SEALED_DEBUG_KEYSTORE="$ANDROID_USER_HOME/debug.keystore"
"$SEALED_JDK_ROOT/bin/keytool" -genkeypair -noprompt \
  -keystore "$SEALED_DEBUG_KEYSTORE" \
  -storepass android -keypass android -alias androiddebugkey \
  -dname 'CN=Android Debug,O=Android,C=US' \
  -keyalg RSA -keysize 2048 -validity 10000 -storetype JKS \
  > "$EVIDENCE/android-debug-keystore-generation.txt" 2>&1
chmod 600 "$SEALED_DEBUG_KEYSTORE"
"$SEALED_JDK_ROOT/bin/keytool" -list -v \
  -keystore "$SEALED_DEBUG_KEYSTORE" -storepass android -alias androiddebugkey \
  > "$EVIDENCE/android-debug-certificate.txt" 2>&1
"$PYTHON" -I -S -B - "$SEALED_DEBUG_KEYSTORE" <<'PY'
import os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
status = os.lstat(path)
if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
    raise SystemExit('isolated Android debug keystore is not a single regular file')
if status.st_uid != os.getuid() or status.st_mode & 0o077:
    raise SystemExit('isolated Android debug keystore permissions/ownership are unsafe')
PY
assert_bootstrap_guard_live
shasum -a 256 "$SEALED_DEBUG_KEYSTORE" \
  > "$EVIDENCE/android-debug-keystore.pre.sha256"
GRADLE_TEMP_PARENT=$(mktemp -d /tmp/telltale-gradle-home.XXXXXX)
GRADLE_TEMP_PARENT=${GRADLE_TEMP_PARENT:A}
GRADLE_USER_HOME="$GRADLE_TEMP_PARENT/home"
GRADLE_CACHE_ARGS=()
DEFAULT_GRADLE_CACHE="$HOST_HOME/.gradle/wrapper/dists/gradle-9.3.1-all"
if [[ -d "$DEFAULT_GRADLE_CACHE" && ! -L "$DEFAULT_GRADLE_CACHE" ]]; then
  GRADLE_CACHE_ARGS=(--cache-root "$DEFAULT_GRADLE_CACHE")
fi
"$PYTHON" -I -S -B "$HERE/prepare_gradle_home.py" \
  --wrapper-properties "$APP_ROOT/android/gradle/wrapper/gradle-wrapper.properties" \
  --destination "$GRADLE_USER_HOME" \
  --evidence "$EVIDENCE/gradle-home-preparation.json" \
  "${GRADLE_CACHE_ARGS[@]}"
ISOLATED_GRADLE_PROPERTIES="$GRADLE_USER_HOME/gradle.properties"
"$PYTHON" -I -S -B - "$ISOLATED_GRADLE_PROPERTIES" \
  "$KOTLIN_PROJECT_PERSISTENT_DIR" "$SEALED_JDK_ROOT" <<'PY'
import os, pathlib, stat, sys

path = pathlib.Path(sys.argv[1])
project_persistent_dir = pathlib.Path(sys.argv[2])
jdk_root = pathlib.Path(sys.argv[3])
parent = path.parent.resolve(strict=True)
parent_status = os.lstat(parent)
if (
    path.parent != parent
    or stat.S_ISLNK(parent_status.st_mode)
    or not stat.S_ISDIR(parent_status.st_mode)
    or parent_status.st_uid != os.getuid()
    or parent_status.st_mode & 0o077
):
    raise SystemExit('isolated Gradle properties parent is unsafe')
project_persistent_status = os.lstat(project_persistent_dir)
if (
    project_persistent_dir.resolve(strict=True) != project_persistent_dir
    or stat.S_ISLNK(project_persistent_status.st_mode)
    or not stat.S_ISDIR(project_persistent_status.st_mode)
    or project_persistent_status.st_uid != os.getuid()
    or project_persistent_status.st_mode & 0o077
    or '\n' in str(project_persistent_dir)
    or '\r' in str(project_persistent_dir)
):
    raise SystemExit('isolated Kotlin project persistent directory is unsafe')
try:
    resolved_jdk_root = jdk_root.resolve(strict=True)
except (OSError, RuntimeError) as error:
    raise SystemExit('isolated Gradle JDK root is unavailable') from error
if (
    resolved_jdk_root != jdk_root
    or not jdk_root.is_dir()
    or any(ord(character) < 32 or ord(character) == 127 for character in str(jdk_root))
    or not (jdk_root / 'bin' / 'java').is_file()
    or not os.access(jdk_root / 'bin' / 'java', os.X_OK)
):
    raise SystemExit('isolated Gradle JDK root is unsafe')
payload = (
    b'org.gradle.daemon=false\n'
    b'org.gradle.logging.stacktrace=full\n'
    + f'org.gradle.java.home={jdk_root}\n'.encode('utf-8')
    + b'kotlin.compiler.execution.strategy=in-process\n'
    b'kotlin.daemon.useFallbackStrategy=false\n'
    + f'kotlin.project.persistent.dir={project_persistent_dir}\n'.encode('utf-8')
)
descriptor = os.open(
    path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0),
    0o600,
)
try:
    written = 0
    while written < len(payload):
        written += os.write(descriptor, payload[written:])
    os.fsync(descriptor)
finally:
    os.close(descriptor)
if path.read_bytes() != payload:
    raise SystemExit('isolated Gradle properties reread mismatch')
PY
ISOLATED_GRADLE_PROPERTIES_SHA256=$(shasum -a 256 \
  "$ISOLATED_GRADLE_PROPERTIES" | awk '{print $1}')
[[ ${#ISOLATED_GRADLE_PROPERTIES_SHA256} == 64 \
  && "$ISOLATED_GRADLE_PROPERTIES_SHA256" != *[^0-9a-f]* ]] \
  || die "isolated Gradle properties digest is invalid"
shasum -a 256 "$ISOLATED_GRADLE_PROPERTIES" \
  > "$EVIDENCE/isolated-gradle-properties.pre.sha256"
assert_bootstrap_guard_live
export GRADLE_USER_HOME

export TELLTALE_GATE_C_SANDBOX_PROFILE=${ANDROID_SDK_SANDBOX_PROFILE:A}
export TELLTALE_GATE_C_SANDBOX_APP_ROOT=${APP_ROOT:A}
export TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT=${SEALED_FLUTTER_ROOT:A}
export TELLTALE_GATE_C_SANDBOX_PUB_CACHE=${SEALED_PUB_CACHE:A}
export TELLTALE_GATE_C_SANDBOX_GRADLE_HOME=${GRADLE_USER_HOME:A}
export TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT=${ISOLATED_USER_TEMP_PARENT:A}
export TELLTALE_GATE_C_SANDBOX_RUN_TEMP=${ANDROID_SDK_SANDBOX_RUN_TEMP:A}
export TELLTALE_GATE_C_SANDBOX_ANDROID_SDK_ROOT=${SEALED_ANDROID_SDK_ROOT:A}
ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE="$EVIDENCE/android-sdk-sandbox.prepare.json"
ANDROID_SDK_SANDBOX_POST_EVIDENCE="$EVIDENCE/android-sdk-sandbox.post.json"
assert_bootstrap_guard_live
BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY=$(create_source_guard_reference_authority \
  bootstrap-source-guard "$BOOTSTRAP_SOURCE_GUARD_PID" \
  "$BOOTSTRAP_SOURCE_GUARD_READY" "$BOOTSTRAP_SOURCE_GUARD_NONCE" \
  "$BOOTSTRAP_SOURCE_GUARD_STOP" "$BOOTSTRAP_SOURCE_GUARD_RESULT") \
  || die "bootstrap source guard reference authority could not be sealed"
build_scope_reference_args --reference-authority \
  || die "bootstrap source guard reference authority is not active"
PROCESS_SCOPE_LAUNCH_ATTEMPT=1
"$PYTHON" -I -S -B "$ANDROID_SDK_SANDBOX_PREFLIGHT" prepare \
  --app-root "$APP_ROOT" \
  --flutter-root "$SEALED_FLUTTER_ROOT" \
  --pub-cache "$SEALED_PUB_CACHE" \
  --gradle-home "$GRADLE_USER_HOME" \
  --isolated-root "$ISOLATED_USER_TEMP_PARENT" \
  --run-temp "$ANDROID_SDK_SANDBOX_RUN_TEMP" \
  --android-sdk-root "$SEALED_ANDROID_SDK_ROOT" \
  --host-home "$HOST_HOME" \
  --profile "$ANDROID_SDK_SANDBOX_PROFILE" \
  --wrapper "$ANDROID_SDK_SANDBOX_EXEC" \
  --probe "$ANDROID_SDK_SANDBOX_PROBE" \
  --python "$PYTHON" \
  --process-scope "$PROCESS_SCOPE_HELPER" \
  --scoped-command "$SCOPED_COMMAND" \
  --owner-root-pid "$GATE_OWNER_ROOT_PID" \
  "${SCOPE_REFERENCE_ARGS[@]}" \
  --output "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE"
PREFLIGHT_PROCESS_SCOPE_AUTHORITY="$EVIDENCE/android-sdk-sandbox-probe.process-authority.json"
[[ -f "$PREFLIGHT_PROCESS_SCOPE_AUTHORITY" \
  && ! -L "$PREFLIGHT_PROCESS_SCOPE_AUTHORITY" \
  && -O "$PREFLIGHT_PROCESS_SCOPE_AUTHORITY" ]] \
  || die "Android SDK sandbox preflight authority is missing or unsafe"
ANDROID_SDK_SANDBOX_PREPARED_SHA256=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" | awk '{print $1}')
[[ ${#ANDROID_SDK_SANDBOX_PREPARED_SHA256} == 64 \
  && "$ANDROID_SDK_SANDBOX_PREPARED_SHA256" != *[^0-9a-f]* ]] \
  || die "Android SDK sandbox prepared evidence digest is invalid"
assert_bootstrap_guard_live
"$PYTHON" -I -S -B - \
  "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
  "$APP_ROOT" "$SEALED_FLUTTER_ROOT" "$SEALED_PUB_CACHE" \
  "$GRADLE_USER_HOME" "$ISOLATED_USER_TEMP_PARENT" \
  "$ANDROID_SDK_SANDBOX_RUN_TEMP" "$SEALED_ANDROID_SDK_ROOT" "$HOST_HOME" \
  "$ANDROID_SDK_SANDBOX_PROFILE" "$ANDROID_SDK_SANDBOX_EXEC" \
  "$ANDROID_SDK_SANDBOX_PROBE" "$PYTHON" \
  "$PROCESS_SCOPE_HELPER" "$SCOPED_COMMAND" \
  "$BOOTSTRAP_SOURCE_GUARD_REFERENCE_AUTHORITY" \
  > "$EVIDENCE/android-sdk-sandbox.prepare-validated.txt" <<'PY'
import hashlib, json, pathlib, re, sys

(
    evidence_text,
    app_root,
    flutter_root,
    pub_cache,
    gradle_home,
    isolated_root,
    run_temp,
    android_sdk_root,
    host_home,
    profile,
    wrapper,
    probe,
    python,
    process_scope,
    scoped_command,
    reference_authority,
) = sys.argv[1:]
evidence = pathlib.Path(evidence_text)
value = json.loads(evidence.read_text(encoding='utf-8'))
if set(value) != {
    'version', 'status', 'paths', 'components', 'sandboxExec', 'androidSdk',
    'probe', 'sessionProof',
}:
    raise SystemExit('Android SDK sandbox prepared evidence schema is invalid')
if value.get('version') != 1 or value.get('status') != 'prepared':
    raise SystemExit('Android SDK sandbox preparation did not pass')
expected_paths = {
    'app_root': app_root,
    'flutter_root': flutter_root,
    'pub_cache': pub_cache,
    'gradle_home': gradle_home,
    'isolated_root': isolated_root,
    'run_temp': run_temp,
    'android_sdk_root': android_sdk_root,
    'host_home': host_home,
}
expected_paths = {
    name: str(pathlib.Path(path).resolve(strict=True))
    for name, path in expected_paths.items()
}
if value.get('paths') != dict(sorted(expected_paths.items())):
    raise SystemExit('Android SDK sandbox prepared path binding is invalid')
expected_components = {
    'profile': profile,
    'wrapper': wrapper,
    'probe': probe,
    'python': python,
    'processScope': process_scope,
    'scopedCommand': scoped_command,
}
components = value.get('components')
if not isinstance(components, dict) or set(components) != set(expected_components):
    raise SystemExit('Android SDK sandbox prepared component set is invalid')
for name, path_text in expected_components.items():
    path = pathlib.Path(path_text).resolve(strict=True)
    fingerprint = components.get(name)
    if (
        not isinstance(fingerprint, dict)
        or fingerprint.get('path') != str(path)
        or fingerprint.get('sha256') != hashlib.sha256(path.read_bytes()).hexdigest()
    ):
        raise SystemExit(f'Android SDK sandbox prepared component is invalid: {name}')
sandbox_exec = value.get('sandboxExec')
if (
    not isinstance(sandbox_exec, dict)
    or sandbox_exec.get('path') != '/usr/bin/sandbox-exec'
    or sandbox_exec.get('verified') is not True
    or sandbox_exec.get('identifier') != 'com.apple.sandbox-exec'
    or re.fullmatch(r'[0-9a-f]+', sandbox_exec.get('cdHash', '')) is None
):
    raise SystemExit('Android SDK sandbox system executable identity is invalid')
known_packages = value.get('androidSdk', {}).get('knownPackages')
expected_known_packages = str(
    pathlib.Path(android_sdk_root).resolve(strict=True) / '.knownPackages'
)
if (
    not isinstance(known_packages, dict)
    or known_packages.get('path') != expected_known_packages
    or re.fullmatch(r'[0-9a-f]{64}', known_packages.get('sha256', '')) is None
):
    raise SystemExit('Android SDK .knownPackages prepared identity is invalid')
probe_result = value.get('probe')
if (
    not isinstance(probe_result, dict)
    or probe_result.get('version') != 1
    or probe_result.get('status') != 'passed'
    or probe_result.get('allowedWrite') is not True
    or probe_result.get('readSucceeded') is not True
    or probe_result.get('sdkOpenWrite', {}).get('denied') is not True
):
    raise SystemExit('Android SDK sandbox enforcement probe is invalid')
session_proof = value.get('sessionProof')
expected_session_paths = {
    'authority': evidence.with_name(
        'android-sdk-sandbox-probe.process-authority.json'
    ),
    'environment': evidence.with_name(
        'android-sdk-sandbox-probe.child-environment.json'
    ),
    'scope': evidence.with_name('android-sdk-sandbox-probe.process-scope.json'),
    'result': evidence.with_name('android-sdk-sandbox-probe.scoped-command.json'),
}
if (
    not isinstance(session_proof, dict)
    or set(session_proof) != set(expected_session_paths) | {'referenceAuthorities'}
):
    raise SystemExit('Android SDK sandbox session proof set is invalid')
for name, path in expected_session_paths.items():
    fingerprint = session_proof.get(name)
    if (
        not isinstance(fingerprint, dict)
        or fingerprint.get('path') != str(path.resolve(strict=True))
        or fingerprint.get('sha256') != hashlib.sha256(path.read_bytes()).hexdigest()
    ):
        raise SystemExit(f'Android SDK sandbox session proof is invalid: {name}')
reference_fingerprints = session_proof.get('referenceAuthorities')
reference_path = pathlib.Path(reference_authority).resolve(strict=True)
if (
    not isinstance(reference_fingerprints, list)
    or len(reference_fingerprints) != 1
    or reference_fingerprints[0].get('path') != str(reference_path)
    or reference_fingerprints[0].get('sha256')
        != hashlib.sha256(reference_path.read_bytes()).hexdigest()
):
    raise SystemExit('Android SDK sandbox reference session proof is invalid')
print('android_sdk_sandbox_prepared_verified=true')
PY
ANDROID_SDK_SANDBOX_PROFILE_SHA256=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_PROFILE" | awk '{print $1}')
ANDROID_SDK_SANDBOX_WRAPPER_SHA256=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_EXEC" | awk '{print $1}')
ANDROID_SDK_SANDBOX_PROBE_SHA256=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_PROBE" | awk '{print $1}')
ANDROID_SDK_SANDBOX_PREFLIGHT_SHA256=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_PREFLIGHT" | awk '{print $1}')
ANDROID_SDK_SANDBOX_EXEC_SHA256=$(shasum -a 256 \
  /usr/bin/sandbox-exec | awk '{print $1}')
PROCESS_SCOPE_HELPER_SHA256=$(shasum -a 256 \
  "$PROCESS_SCOPE_HELPER" | awk '{print $1}')
SCOPED_COMMAND_SHA256=$(shasum -a 256 \
  "$SCOPED_COMMAND" | awk '{print $1}')
for sandbox_digest in \
  "$ANDROID_SDK_SANDBOX_PROFILE_SHA256" \
  "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
  "$ANDROID_SDK_SANDBOX_PROBE_SHA256" \
  "$ANDROID_SDK_SANDBOX_PREFLIGHT_SHA256" \
  "$ANDROID_SDK_SANDBOX_EXEC_SHA256" \
  "$PROCESS_SCOPE_HELPER_SHA256" \
  "$SCOPED_COMMAND_SHA256"; do
  [[ ${#sandbox_digest} == 64 && "$sandbox_digest" != *[^0-9a-f]* ]] \
    || die "Android SDK sandbox component digest is invalid"
done
{
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PROFILE"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_EXEC"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PROBE"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PREFLIGHT"
  shasum -a 256 /usr/bin/sandbox-exec
  shasum -a 256 "$PROCESS_SCOPE_HELPER"
  shasum -a 256 "$SCOPED_COMMAND"
} > "$EVIDENCE/android-sdk-sandbox-components.pre.sha256"

assert_android_sdk_sandbox_binding() {
  [[ ${TELLTALE_GATE_C_SANDBOX_PROFILE:A} \
      == ${ANDROID_SDK_SANDBOX_PROFILE:A} \
    && ${TELLTALE_GATE_C_SANDBOX_APP_ROOT:A} == ${APP_ROOT:A} \
    && ${TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT:A} \
      == ${SEALED_FLUTTER_ROOT:A} \
    && ${TELLTALE_GATE_C_SANDBOX_PUB_CACHE:A} == ${SEALED_PUB_CACHE:A} \
    && ${TELLTALE_GATE_C_SANDBOX_GRADLE_HOME:A} == ${GRADLE_USER_HOME:A} \
    && ${TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT:A} \
      == ${ISOLATED_USER_TEMP_PARENT:A} \
    && ${TELLTALE_GATE_C_SANDBOX_RUN_TEMP:A} \
      == ${ANDROID_SDK_SANDBOX_RUN_TEMP:A} \
    && ${TELLTALE_GATE_C_SANDBOX_ANDROID_SDK_ROOT:A} \
      == ${SEALED_ANDROID_SDK_ROOT:A} ]] \
    || die "Android SDK sandbox environment binding changed"
  [[ -f "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
    && ! -L "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
    && -O "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
    && $(shasum -a 256 "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
      | awk '{print $1}') == "$ANDROID_SDK_SANDBOX_PREPARED_SHA256" ]] \
    || die "Android SDK sandbox prepared evidence changed"
  [[ -f "$ISOLATED_GRADLE_PROPERTIES" \
    && ! -L "$ISOLATED_GRADLE_PROPERTIES" \
    && -O "$ISOLATED_GRADLE_PROPERTIES" \
    && $(shasum -a 256 "$ISOLATED_GRADLE_PROPERTIES" \
      | awk '{print $1}') == "$ISOLATED_GRADLE_PROPERTIES_SHA256" ]] \
    || die "isolated Gradle properties changed"
  for kotlin_dir in \
    "$KOTLIN_PROJECT_PERSISTENT_DIR" "$KOTLIN_DAEMON_RUN_FILES_DIR"; do
    [[ -d "$kotlin_dir" && ! -L "$kotlin_dir" && -O "$kotlin_dir" \
      && ${kotlin_dir:A:h} == ${ANDROID_SDK_SANDBOX_RUN_TEMP:A} ]] \
      || die "isolated Kotlin runtime directory changed: $kotlin_dir"
  done
  [[ $(shasum -a 256 "$ANDROID_SDK_SANDBOX_PROFILE" | awk '{print $1}') \
      == "$ANDROID_SDK_SANDBOX_PROFILE_SHA256" \
    && $(shasum -a 256 "$ANDROID_SDK_SANDBOX_EXEC" | awk '{print $1}') \
      == "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
    && $(shasum -a 256 "$ANDROID_SDK_SANDBOX_PROBE" | awk '{print $1}') \
      == "$ANDROID_SDK_SANDBOX_PROBE_SHA256" \
    && $(shasum -a 256 "$ANDROID_SDK_SANDBOX_PREFLIGHT" | awk '{print $1}') \
      == "$ANDROID_SDK_SANDBOX_PREFLIGHT_SHA256" \
    && $(shasum -a 256 /usr/bin/sandbox-exec | awk '{print $1}') \
      == "$ANDROID_SDK_SANDBOX_EXEC_SHA256" \
    && $(shasum -a 256 "$PROCESS_SCOPE_HELPER" | awk '{print $1}') \
      == "$PROCESS_SCOPE_HELPER_SHA256" \
    && $(shasum -a 256 "$SCOPED_COMMAND" | awk '{print $1}') \
      == "$SCOPED_COMMAND_SHA256" ]] \
    || die "Android SDK sandbox component identity changed"
}
assert_android_sdk_sandbox_binding

validate_child_environment_evidence() {
  local authority=$1
  "$PYTHON" -I -S -B - "$authority" <<'PY'
import hashlib, json, os, pathlib, re, stat, sys

class DuplicateKey(ValueError):
    pass

def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKey(f'duplicate key: {key!r}')
        value[key] = item
    return value

def load(path, label):
    try:
        return json.loads(
            path.read_bytes(), object_pairs_hook=reject_duplicate_keys
        )
    except (json.JSONDecodeError, UnicodeDecodeError, DuplicateKey) as error:
        raise SystemExit(f'{label} JSON is invalid: {error}') from error

def canonical_sha256(value):
    payload = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(payload).hexdigest()

authority_path = pathlib.Path(sys.argv[1])
authority = load(authority_path, 'process authority')
launch_id = authority.get('launchId') if isinstance(authority, dict) else None
if not isinstance(launch_id, str) or re.fullmatch(r'[0-9a-f]{32}', launch_id) is None:
    raise SystemExit('process authority launch ID is invalid')
suffix = '.process-authority.json'
if not authority_path.name.endswith(suffix):
    raise SystemExit('process authority evidence path is invalid')
environment_path = authority_path.with_name(
    authority_path.name[:-len(suffix)] + '.child-environment.json'
)
try:
    canonical = environment_path.resolve(strict=True)
except (OSError, RuntimeError) as error:
    raise SystemExit('child-environment evidence is missing') from error
if canonical != environment_path:
    raise SystemExit('child-environment evidence path is not canonical')
current = pathlib.Path(environment_path.anchor)
for part in environment_path.parts[1:]:
    current /= part
    if stat.S_ISLNK(current.lstat().st_mode):
        raise SystemExit('child-environment evidence path contains a symlink')
metadata = environment_path.lstat()
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_uid != os.getuid()
    or stat.S_IMODE(metadata.st_mode) != 0o600
    or metadata.st_nlink != 1
):
    raise SystemExit('child-environment evidence is not a private owner file')
value = load(environment_path, 'child-environment evidence')
required = {
    'schema', 'version', 'launchId', 'allowedNames', 'allowedNamesSha256',
    'actualNames', 'actualNamesSha256', 'actualNamesObservationPoint',
    'producerPlannedEnvironmentValuesSha256', 'plannedNamesMatchBarrier',
    'valuesObserved', 'postBarrierAddedNames',
    'credentialNamesAssertedAbsent', 'forbiddenCredentialNamesPresent',
}
runtime_names = {
    'TELLTALE_GATE_C_PROCESS_SCOPE',
    'TELLTALE_GATE_C_LAUNCH_RELEASE_FD',
    'TELLTALE_GATE_C_LAUNCH_READY_FD',
}
allowed_names = sorted({
    'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_USER_HOME',
    'GRADLE_USER_HOME', 'HOME', 'JAVA_HOME', 'LANG', 'LC_ALL',
    'ORG_GRADLE_PROJECT_telltaleGateCRigDebug', 'PATH', 'PWD', 'PUB_CACHE',
    'TELLTALE_GATE_C_FLUTTER_ROOT', 'TELLTALE_GATE_C_JDK_ROOT',
    'TELLTALE_GATE_C_SANDBOX_ANDROID_SDK_ROOT',
    'TELLTALE_GATE_C_SANDBOX_APP_ROOT',
    'TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT',
    'TELLTALE_GATE_C_SANDBOX_GRADLE_HOME',
    'TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT',
    'TELLTALE_GATE_C_SANDBOX_PROFILE',
    'TELLTALE_GATE_C_SANDBOX_PUB_CACHE',
    'TELLTALE_GATE_C_SANDBOX_RUN_TEMP',
    'TELLTALE_GATE_C_PROCESS_SCOPE',
    'TELLTALE_GATE_C_LAUNCH_RELEASE_FD',
    'TELLTALE_GATE_C_LAUNCH_READY_FD',
    'XDG_CONFIG_HOME',
})
credential_names = sorted({
    'ARBITRARY_SECRET', 'HF_TOKEN', 'OP_SERVICE_ACCOUNT_TOKEN', 'SSH_AUTH_SOCK',
})
actual_names = value.get('actualNames') if isinstance(value, dict) else None
if (
    not isinstance(actual_names, list)
    or any(
        not isinstance(name, str)
        or re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name) is None
        for name in actual_names
    )
    or actual_names != sorted(set(actual_names))
):
    raise SystemExit('child-environment actual names are invalid')
if (
    not isinstance(value, dict)
    or set(value) != required
    or value.get('schema') != 'telltale-gate-c-child-environment-names-v2'
    or value.get('version') != 2
    or value.get('launchId') != launch_id
    or value.get('allowedNames') != allowed_names
    or value.get('allowedNamesSha256') != canonical_sha256(allowed_names)
    or not set(actual_names).issubset(allowed_names)
    or not runtime_names.issubset(actual_names)
    or value.get('actualNamesSha256') != canonical_sha256(actual_names)
    or value.get('actualNamesObservationPoint') != 'cooperative-sealed-wrapper-pre-release-barrier-v1'
    or re.fullmatch(
        r'[0-9a-f]{64}', value.get('producerPlannedEnvironmentValuesSha256', '')
    ) is None
    or value.get('plannedNamesMatchBarrier') is not True
    or value.get('valuesObserved') is not False
    or value.get('postBarrierAddedNames')
      != ['FLUTTER_ALREADY_LOCKED', 'JAVA_TOOL_OPTIONS', 'TMPDIR']
    or value.get('credentialNamesAssertedAbsent') != credential_names
    or value.get('forbiddenCredentialNamesPresent') != []
):
    raise SystemExit('child-environment evidence binding is invalid')
print(f'child_environment_evidence={environment_path}')
PY
}

validate_scoped_sandbox_result() {
  local label=$1 expected_status=$2
  local authority="$PROCESS_SCOPE_AUTHORITY_DIR/$label.process-authority.json"
  local scope_evidence="$EVIDENCE/$label.process-scope.json"
  local result="$EVIDENCE/$label.scoped-command.json"
  validate_gradle_process_scope_evidence \
    "$label" "$scope_evidence" "$authority" || return 1
  validate_child_environment_evidence "$authority" || return 1
  "$PYTHON" -I -S -B - \
    "$result" "$authority" "$scope_evidence" "$label" "$expected_status" <<'PY'
import hashlib, json, pathlib, sys

result_path, authority_path, scope_path = map(pathlib.Path, sys.argv[1:4])
label, expected_status = sys.argv[4:]
result = json.loads(result_path.read_text(encoding='utf-8'))
authority = json.loads(authority_path.read_text(encoding='utf-8'))
scope = json.loads(scope_path.read_text(encoding='utf-8'))
required = {
    'version', 'label', 'status', 'commandExitCode', 'authority',
    'scopeTermination', 'authoritySha256', 'childPid', 'scopeEvidenceSha256',
}
if (
    set(result) != required
    or result.get('version') != 1
    or result.get('label') != label
    or result.get('status') != expected_status
    or result.get('authority') != authority
    or result.get('scopeTermination') != scope
    or result.get('authoritySha256')
        != hashlib.sha256(authority_path.read_bytes()).hexdigest()
    or result.get('scopeEvidenceSha256')
        != hashlib.sha256(scope_path.read_bytes()).hexdigest()
    or result.get('childPid') != authority.get('leader', {}).get('pid')
    or type(result.get('commandExitCode')) is not int
    or (expected_status == 'completed' and result['commandExitCode'] != 0)
    or (expected_status == 'command_failed' and result['commandExitCode'] == 0)
):
    raise SystemExit('scoped sandbox command result binding is invalid')
print(f'scoped_command_label={label}')
print(f'scoped_command_status={expected_status}')
PY
}

run_scoped_sandbox_command() {
  local label=$1 cwd=$2 helper_exit
  local authority="$PROCESS_SCOPE_AUTHORITY_DIR/$label.process-authority.json"
  local scope_evidence="$EVIDENCE/$label.process-scope.json"
  local result="$EVIDENCE/$label.scoped-command.json"
  shift 2
  [[ -n "$label" && "$label" != *[^a-z0-9-]* ]] || return 64
  # Only the authorized child may write to this function's stdout. Keep all
  # control-plane validation diagnostics on stderr so command substitutions
  # cannot mistake provenance messages for tool output.
  assert_android_sdk_sandbox_binding >&2
  build_scope_reference_args --reference-authority >&2 \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  PROCESS_SCOPE_LAUNCH_ATTEMPT=1
  if "$PYTHON" -I -S -B "$SCOPED_COMMAND" \
    --authority "$authority" \
    --scope-evidence "$scope_evidence" \
    --result "$result" \
    --label "$label" \
    --cwd "$cwd" \
    --owner-root-pid "$GATE_OWNER_ROOT_PID" \
    --wrapper "$ANDROID_SDK_SANDBOX_EXEC" \
    --wrapper-sha256 "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
    "${SCOPE_REFERENCE_ARGS[@]}" \
    -- "$@"; then
    helper_exit=0
  else
    helper_exit=$?
  fi
  validate_scoped_sandbox_result "$label" \
    $([[ $helper_exit == 0 ]] && print completed || print command_failed) >&2 \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  (( helper_exit == 0 )) || return "$helper_exit"
  assert_android_sdk_sandbox_binding >&2
}

start_scoped_sandbox_command() {
  local label=$1 cwd=$2 log=$3
  local authority="$PROCESS_SCOPE_AUTHORITY_DIR/$label.process-authority.json"
  local scope_evidence="$EVIDENCE/$label.process-scope.json"
  local result="$EVIDENCE/$label.scoped-command.json"
  shift 3
  [[ -n "$label" && "$label" != *[^a-z0-9-]* ]] || return 64
  assert_android_sdk_sandbox_binding
  build_scope_reference_args --reference-authority \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  PROCESS_SCOPE_LAUNCH_ATTEMPT=1
  "$PYTHON" -I -S -B "$SCOPED_COMMAND" \
    --authority "$authority" \
    --scope-evidence "$scope_evidence" \
    --result "$result" \
    --label "$label" \
    --cwd "$cwd" \
    --owner-root-pid "$GATE_OWNER_ROOT_PID" \
    --wrapper "$ANDROID_SDK_SANDBOX_EXEC" \
    --wrapper-sha256 "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
    "${SCOPE_REFERENCE_ARGS[@]}" \
    -- "$@" >"$log" 2>&1 &
  SCOPED_COMMAND_PID=$!
}

run_scoped_sandbox_command gradle-version "$APP_ROOT/android" \
  "$ANDROID_SDK_SANDBOX_EXEC" -- ./gradlew --no-daemon --version \
  > "$EVIDENCE/gradle-version.txt" 2>&1 \
  || die "Gradle version command or process scope failed"
assert_android_sdk_sandbox_binding
assert_bootstrap_guard_live
GRADLE_DIST_ROOT=$("$PYTHON" -I -S -B - \
  "$EVIDENCE/gradle-home-preparation.json" "$GRADLE_USER_HOME" <<'PY'
import json, os, pathlib, re, stat, sys

value = json.load(open(sys.argv[1], encoding='utf-8'))
raw = value.get('destinationZip') if isinstance(value, dict) else None
if not isinstance(raw, str) or not raw.endswith('.zip'):
    raise SystemExit('invalid prepared Gradle distribution evidence')
archive = pathlib.Path(raw)
raw_home = pathlib.Path(sys.argv[2])
home = raw_home.resolve(strict=True)
if not archive.is_absolute() or any(ord(character) < 32 or ord(character) == 127 for character in raw):
    raise SystemExit('invalid prepared Gradle distribution destination')
home_status = os.lstat(home)
if (
    raw_home != home
    or stat.S_ISLNK(home_status.st_mode)
    or not stat.S_ISDIR(home_status.st_mode)
    or home_status.st_uid != os.getuid()
    or home_status.st_mode & 0o022
):
    raise SystemExit('isolated Gradle home is unsafe')
stem = archive.name.removesuffix('.zip')
match = re.fullmatch(
    r'(?P<root>gradle-[0-9]+(?:\.[0-9]+)*(?:-[a-z0-9.-]+)?)-(?:all|bin)',
    stem,
)
if match is None:
    raise SystemExit('unsupported prepared Gradle distribution filename')
try:
    relative = archive.relative_to(home)
except ValueError as error:
    raise SystemExit('prepared Gradle distribution escaped isolated home') from error
if (
    len(relative.parts) != 5
    or relative.parts[:2] != ('wrapper', 'dists')
    or relative.parts[2] != stem
    or not re.fullmatch(r'[0-9a-z]+', relative.parts[3])
    or relative.parts[4] != archive.name
):
    raise SystemExit('prepared Gradle distribution destination layout is invalid')

current = home
for part in relative.parts[:-1]:
    current /= part
    status = os.lstat(current)
    if (
        stat.S_ISLNK(status.st_mode)
        or not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.getuid()
        or status.st_mode & 0o022
    ):
        raise SystemExit(f'unsafe prepared Gradle distribution ancestor: {current}')
if archive.exists() or archive.is_symlink():
    status = os.lstat(archive)
    if (
        stat.S_ISLNK(status.st_mode)
        or not stat.S_ISREG(status.st_mode)
        or status.st_nlink != 1
        or status.st_uid != os.getuid()
        or status.st_mode & 0o022
    ):
        raise SystemExit('prepared Gradle distribution archive is unsafe')

root = archive.parent / match.group('root')
status = os.lstat(root)
if (
    stat.S_ISLNK(status.st_mode)
    or not stat.S_ISDIR(status.st_mode)
    or status.st_uid != os.getuid()
    or status.st_mode & 0o022
    or root.resolve(strict=True) != root
):
    raise SystemExit('prepared Gradle distribution was not extracted safely')
print(root)
PY
)
"$PYTHON" -I -S -B - "$EVIDENCE/gradle-version.txt" "$SEALED_JDK_ROOT" \
  > "$EVIDENCE/gradle-jvm-validated.txt" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
matches = [line.split(':', 1)[1].strip().split(' (', 1)[0] for line in lines
           if line.startswith('Daemon JVM:')]
if len(matches) != 1:
    raise SystemExit('Gradle version output does not contain one Daemon JVM')
actual = pathlib.Path(matches[0]).resolve(strict=True)
expected = pathlib.Path(sys.argv[2]).resolve(strict=True)
if actual != expected:
    raise SystemExit(f'Gradle Daemon JVM mismatch: actual={actual} expected={expected}')
print(f'daemon_jvm={actual}')
print('daemon_jvm_verified=true')
PY
for forbidden in \
  "$GRADLE_USER_HOME/init.gradle" \
  "$GRADLE_USER_HOME/init.gradle.kts" \
  "$GRADLE_USER_HOME/init.d"; do
  [[ ! -e "$forbidden" && ! -L "$forbidden" ]] \
    || die "isolated Gradle home contains forbidden user configuration: $forbidden"
done

# Every later Gradle invocation is an explicitly requested RigDebug evidence
# task. The build script validates that scope before using this property and,
# when valid, never opens android/key.properties or any release keystore.
export ORG_GRADLE_PROJECT_telltaleGateCRigDebug=true



assert_toolchain_binding() {
  local configured_android_sdk
  assert_android_sdk_sandbox_binding
  configured_android_sdk=$("$PYTHON" -I -S -B "$HERE/tree_manifest.py" android-sdk-root \
    --root "$APP_ROOT") \
    || die "android/local.properties Android SDK could not be resolved"
  [[ ${configured_android_sdk:A} == ${SEALED_ANDROID_SDK_ROOT:A} ]] \
    || die "android/local.properties Android SDK changed during the live rig"
  [[ ${JAVA_HOME:A} == ${SEALED_JDK_ROOT:A} ]] \
    || die "JAVA_HOME changed during the live rig"
  [[ ${HOME:A} == ${ISOLATED_USER_TEMP_PARENT:A}/home \
    && ${XDG_CONFIG_HOME:A} == ${ISOLATED_USER_TEMP_PARENT:A}/xdg-config \
    && ${ANDROID_USER_HOME:A} == ${ISOLATED_USER_TEMP_PARENT:A}/android-user-home ]] \
    || die "isolated user/config home binding changed during the live rig"
  [[ ${PUB_CACHE:A} == ${SEALED_PUB_CACHE:A} ]] \
    || die "Dart pub cache binding changed during the live rig"
  [[ ${ANDROID_HOME:A} == ${SEALED_ANDROID_SDK_ROOT:A} \
    && ${ANDROID_SDK_ROOT:A} == ${SEALED_ANDROID_SDK_ROOT:A} ]] \
    || die "Android SDK environment changed during the live rig"
  [[ ${ADB:A} == ${EXPECTED_ADB:A} ]] \
    || die "ADB changed during the live rig"
  [[ -d "$GRADLE_DIST_ROOT" && ! -L "$GRADLE_DIST_ROOT" ]] \
    || die "isolated Gradle distribution disappeared or became unsafe"
  [[ ${GRADLE_USER_HOME:A} == ${GRADLE_TEMP_PARENT:A}/home ]] \
    || die "isolated Gradle user-home binding changed during the live rig"
  [[ ${ORG_GRADLE_PROJECT_telltaleGateCRigDebug:-} == true ]] \
    || die "Gate C RigDebug Gradle property changed during the live rig"
  [[ ${TELLTALE_GATE_C_FLUTTER_ROOT:A} == ${SEALED_FLUTTER_ROOT:A} ]] \
    || die "Gate C nested Flutter root changed during the live rig"
  [[ ${TELLTALE_GATE_C_JDK_ROOT:A} == ${SEALED_JDK_ROOT:A} ]] \
    || die "Gate C build JDK root changed during the live rig"
  [[ -x "$PYTHON" && -f "$PYTHON" && ! -L "$PYTHON" ]] \
    || die "bound Python executable disappeared or became unsafe"
  [[ $(shasum -a 256 "$PYTHON" | awk '{print $1}') == "$PYTHON_SHA256" ]] \
    || die "bound Python executable changed during the live rig"
  assert_isolated_flutter_config >/dev/null \
    || die "isolated Flutter configuration changed during the live rig"
  shasum -a 256 -c "$EVIDENCE/flutter-settings.pre.sha256" >/dev/null \
    || die "isolated Flutter settings hash changed during the live rig"
  shasum -a 256 -c "$EVIDENCE/android-debug-keystore.pre.sha256" >/dev/null \
    || die "isolated Android debug keystore changed during the live rig"
}
assert_toolchain_binding
[[ $($ADB -s "$SERIAL" get-state 2>/dev/null || true) == device ]] \
  || die "device $SERIAL is not authorized/online"

ANDROID_TOOLCHAIN_COMMON_ARGS=(
  --root "$APP_ROOT"
  --expected-sdk-root "$SEALED_ANDROID_SDK_ROOT"
  --expected-jdk-root "$SEALED_JDK_ROOT"
  --expected-adb "$EXPECTED_ADB"
  --expected-gradle-root "$GRADLE_DIST_ROOT"
)
ANDROID_COMPONENT_ARGS=()

write_tested_tree_manifest() {
  local output=$1
  "$PYTHON" -I -S -B "$HERE/tree_manifest.py" write \
    --root "$APP_ROOT" --manifest "$output" \
    --expected-flutter-root "$SEALED_FLUTTER_ROOT"
}

assert_source_guard_live() {
  [[ ${SOURCE_GUARD_PID:-} == <-> ]] \
    || die "source-tree guard PID is unavailable"
  kill -0 "$SOURCE_GUARD_PID" 2>/dev/null \
    || die "source-tree guard exited before the authorized stop"
  [[ -n ${SOURCE_GUARD_STOP:-} && ! -e "$SOURCE_GUARD_STOP" ]] \
    || die "source-tree guard stop control appeared before authorization"
  [[ -n ${SOURCE_GUARD_READY:-} && -f "$SOURCE_GUARD_READY" ]] \
    || die "source-tree guard readiness evidence disappeared"
  [[ -n ${SOURCE_GUARD_RESULT:-} && ! -e "$SOURCE_GUARD_RESULT" ]] \
    || die "source-tree guard produced an early terminal result"
}

run_guarded_command() {
  local label=$1 log=$2 result=$3 cwd=$4 helper_exit supervisor_pid
  local scope_evidence="$EVIDENCE/$label-process-scope.json"
  local scope_authority="$PROCESS_SCOPE_AUTHORITY_DIR/$label.process-authority.json"
  shift 4
  assert_source_guard_live
  assert_android_sdk_sandbox_binding
  build_scope_reference_args --scope-reference-authority \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  PROCESS_SCOPE_LAUNCH_ATTEMPT=1
  "$PYTHON" -I -S -B "$HERE/guarded_command.py" \
    --guard-pid "$SOURCE_GUARD_PID" \
    --guard-ready "$SOURCE_GUARD_READY" \
    --guard-result "$SOURCE_GUARD_RESULT" \
    --guard-nonce "$SOURCE_GUARD_NONCE" \
    --log "$log" \
    --result "$result" \
    --label "$label" \
    --cwd "$cwd" \
    --scope-authority "$scope_authority" \
    --scope-evidence "$scope_evidence" \
    --scope-owner-root-pid "$GATE_OWNER_ROOT_PID" \
    --scope-wrapper "$ANDROID_SDK_SANDBOX_EXEC" \
    --scope-wrapper-sha256 "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
    "${SCOPE_REFERENCE_ARGS[@]}" \
    -- "$@" &
  supervisor_pid=$!
  GUARDED_COMMAND_PID=$supervisor_pid
  bounded_reap "$supervisor_pid" \
    "$EVIDENCE/$label-supervisor-exit.txt" \
    guarded-command-supervisor 1800000 12000 2000
  helper_exit=$?
  if ! kill -0 "$supervisor_pid" 2>/dev/null; then
    GUARDED_COMMAND_PID=''
  fi
  validate_gradle_process_scope_evidence \
    "$label" "$scope_evidence" "$scope_authority" \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  validate_child_environment_evidence "$scope_authority" \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
  "$PYTHON" -I -S -B - "$result" "$scope_evidence" "$scope_authority" \
    "$label" "$SOURCE_GUARD_PID" "$helper_exit" <<'PY' \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; return 72; }
import hashlib, json, pathlib, sys

supervisor = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
scope_path = pathlib.Path(sys.argv[2])
authority_path = pathlib.Path(sys.argv[3])
expected_label = sys.argv[4]
expected_guard_pid = int(sys.argv[5])
helper_exit = int(sys.argv[6])
scope = json.loads(scope_path.read_text(encoding='utf-8'))
authority = json.loads(authority_path.read_text(encoding='utf-8'))
required = {
    'version', 'label', 'guardPid', 'guardExitObserved', 'commandExitCode',
    'termination', 'scopeTermination', 'status', 'childPid', 'childPgid',
    'scopeAuthority', 'scopeAuthoritySha256', 'scopeEvidenceSha256',
    'logSha256',
}
command_exit = supervisor.get('commandExitCode')
status = supervisor.get('status')
expected_helper_exit = (
    command_exit
    if type(command_exit) is int and 0 < command_exit < 126
    else 0 if command_exit == 0
    else 1
)
terminal_result_is_consistent = (
    type(command_exit) is int
    and (
        (status == 'completed' and command_exit == 0)
        or (status == 'command_failed' and command_exit != 0)
    )
    and helper_exit == expected_helper_exit
)
if (
    set(supervisor) != required
    or supervisor.get('version') != 1
    or supervisor.get('label') != expected_label
    or supervisor.get('guardPid') != expected_guard_pid
    or supervisor.get('guardExitObserved') is not False
    or not terminal_result_is_consistent
    or supervisor.get('termination') != 'natural_exit'
    or supervisor.get('childPid') != authority.get('leader', {}).get('pid')
    or supervisor.get('childPgid') != authority.get('leader', {}).get('pgid')
    or supervisor.get('scopeTermination') != scope
    or supervisor.get('scopeEvidenceSha256')
        != hashlib.sha256(scope_path.read_bytes()).hexdigest()
    or supervisor.get('scopeAuthority') != authority
    or supervisor.get('scopeAuthoritySha256')
        != hashlib.sha256(authority_path.read_bytes()).hexdigest()
):
    raise SystemExit('guarded command process-scope evidence binding failed')
print('guarded_process_scope_binding_verified=true')
PY
  if (( helper_exit == 72 )); then
    GRADLE_FORENSIC_RETENTION_LATCH=1
  fi
  (( helper_exit == 0 )) || return "$helper_exit"
  assert_android_sdk_sandbox_binding
  assert_source_guard_live
  return 0
}

verify_tested_tree() {
  assert_flutter_binding
  assert_toolchain_binding
  assert_source_guard_live
  "$PYTHON" -I -S -B "$HERE/tree_manifest.py" verify \
    --root "$APP_ROOT" --manifest "$EVIDENCE/tested-files.pre.sha256" \
    --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
    || die "tested tree changed during the live rig"
  assert_flutter_binding
  assert_toolchain_binding
  assert_source_guard_live
}

device_state_snapshot() {
  local output=$1
  gate_c_adb_snapshot "$output"
}

device_state_snapshot "$EVIDENCE/before-state.txt" \
  || die "could not capture a fail-closed initial device-state snapshot"
BEFORE_FONT_SCALE=$(awk -F= '/^font_scale=/{print substr($0,index($0,"=")+1)}' "$EVIDENCE/before-state.txt")
BEFORE_ACCELEROMETER_ROTATION=$(awk -F= '/^accelerometer_rotation=/{print substr($0,index($0,"=")+1)}' "$EVIDENCE/before-state.txt")
BEFORE_USER_ROTATION=$(awk -F= '/^user_rotation=/{print substr($0,index($0,"=")+1)}' "$EVIDENCE/before-state.txt")
BEFORE_FIELD_PATH=$(awk -F= '/^field_path=/{print substr($0,index($0,"=")+1)}' "$EVIDENCE/before-state.txt")
BEFORE_FIELD_PID=$(awk -F= '/^field_pid=/{print substr($0,index($0,"=")+1)}' "$EVIDENCE/before-state.txt")
CURRENT_DRIVER=''
GATE_CURRENT_DRIVER=''
SOURCE_GUARD_PID=''
SOURCE_GUARD_STOP=''
SOURCE_GUARD_READY=''
SOURCE_GUARD_EVENTS=''
SOURCE_GUARD_EVENTS_LIVE=''
SOURCE_GUARD_RESULT=''
SOURCE_GUARD_NONCE=''
GUARDED_COMMAND_PID=''
CLEANUP_DONE=0
CLEANUP_ATTEMPT=0

ensure_rig_absent() {
  gate_c_adb_remove_rig_package "$1"
}

cleanup_rig() {
  local rig_path=unknown rig_pid=unknown after_font=unknown after_accel=unknown
  local after_rotation=unknown after_field=unknown after_field_pid=unknown cleanup_ok=1
  local suffix=''
  local current_driver_pid=$CURRENT_DRIVER gate_driver_pid=$GATE_CURRENT_DRIVER
  (( CLEANUP_ATTEMPT += 1 ))
  (( CLEANUP_ATTEMPT == 1 )) || suffix=".retry-$CLEANUP_ATTEMPT"
  set +e
  if [[ "$GUARDED_COMMAND_PID" == <-> ]]; then
    cleanup_reap_child "$GUARDED_COMMAND_PID" \
      "$EVIDENCE/cleanup-guarded-command${suffix}.txt" \
      guarded-command-supervisor 0 12000 2000 \
      || cleanup_ok=0
    kill -0 "$GUARDED_COMMAND_PID" 2>/dev/null \
      || GUARDED_COMMAND_PID=''
  fi
  if [[ "$current_driver_pid" == <-> ]]; then
    cleanup_reap_child "$current_driver_pid" \
      "$EVIDENCE/cleanup-current-driver${suffix}.txt" \
      cleanup-current-driver 0 2000 2000 \
      || cleanup_ok=0
    kill -0 "$current_driver_pid" 2>/dev/null || CURRENT_DRIVER=''
  fi
  if [[ "$gate_driver_pid" == <-> && "$gate_driver_pid" != "$current_driver_pid" ]]; then
    cleanup_reap_child "$gate_driver_pid" \
      "$EVIDENCE/cleanup-gate-driver${suffix}.txt" \
      cleanup-gate-driver 0 2000 2000 \
      || cleanup_ok=0
    kill -0 "$gate_driver_pid" 2>/dev/null || GATE_CURRENT_DRIVER=''
  elif [[ "$gate_driver_pid" == "$current_driver_pid" && -z "$CURRENT_DRIVER" ]]; then
    GATE_CURRENT_DRIVER=''
  fi
  if [[ "$SOURCE_GUARD_PID" == <-> ]]; then
    if [[ -z "$SOURCE_GUARD_STOP" ]] || ! touch "$SOURCE_GUARD_STOP"; then
      cleanup_ok=0
    fi
    cleanup_reap_child "$SOURCE_GUARD_PID" \
      "$EVIDENCE/cleanup-source-tree-guard${suffix}.txt" \
      source-tree-guard 10000 2000 2000 \
      || cleanup_ok=0
    kill -0 "$SOURCE_GUARD_PID" 2>/dev/null || SOURCE_GUARD_PID=''
  fi
  if [[ "$SOURCE_GUARD_PID" == <-> ]] \
    && kill -0 "$SOURCE_GUARD_PID" 2>/dev/null; then
    cleanup_ok=0
  else
    preserve_guard_event_ledger \
      "$SOURCE_GUARD_EVENTS_LIVE" "$SOURCE_GUARD_EVENTS" \
      "$EVIDENCE/source-tree-guard-ledger-preservation.json" \
      || cleanup_ok=0
  fi
  if [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]]; then
    if [[ -z "$BOOTSTRAP_SOURCE_GUARD_STOP" ]] \
      || ! touch "$BOOTSTRAP_SOURCE_GUARD_STOP"; then
      cleanup_ok=0
    fi
    cleanup_reap_child "$BOOTSTRAP_SOURCE_GUARD_PID" \
      "$EVIDENCE/cleanup-bootstrap-source-tree-guard${suffix}.txt" \
      bootstrap-source-tree-guard 10000 2000 2000 \
      || cleanup_ok=0
    kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null \
      || BOOTSTRAP_SOURCE_GUARD_PID=''
  fi
  if [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]] \
    && kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null; then
    cleanup_ok=0
  else
    preserve_guard_event_ledger \
      "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
      "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
      "$EVIDENCE/bootstrap-source-tree-guard-ledger-preservation.json" \
      || cleanup_ok=0
  fi
  if ! gate_c_adb_remove_rig_package \
    "$EVIDENCE/final-rig-removal${suffix}.txt"; then
    cleanup_ok=0
  fi
  local after_state="$EVIDENCE/after-state${suffix}.txt"
  if device_state_snapshot "$after_state"; then
    rig_path=$(awk -F= '/^rig_path=/{print substr($0,index($0,"=")+1)}' "$after_state")
    rig_pid=$(awk -F= '/^rig_pid=/{print substr($0,index($0,"=")+1)}' "$after_state")
    after_font=$(awk -F= '/^font_scale=/{print substr($0,index($0,"=")+1)}' "$after_state")
    after_accel=$(awk -F= '/^accelerometer_rotation=/{print substr($0,index($0,"=")+1)}' "$after_state")
    after_rotation=$(awk -F= '/^user_rotation=/{print substr($0,index($0,"=")+1)}' "$after_state")
    after_field=$(awk -F= '/^field_path=/{print substr($0,index($0,"=")+1)}' "$after_state")
    after_field_pid=$(awk -F= '/^field_pid=/{print substr($0,index($0,"=")+1)}' "$after_state")
  else
    cleanup_ok=0
  fi
  [[ "$rig_path" == absent && "$rig_pid" == absent ]] || cleanup_ok=0
  [[ "$after_font" == "$BEFORE_FONT_SCALE" ]] || cleanup_ok=0
  [[ "$after_accel" == "$BEFORE_ACCELEROMETER_ROTATION" ]] || cleanup_ok=0
  [[ "$after_rotation" == "$BEFORE_USER_ROTATION" ]] || cleanup_ok=0
  [[ "$after_field" == "$BEFORE_FIELD_PATH" ]] || cleanup_ok=0
  [[ "$after_field_pid" == "$BEFORE_FIELD_PID" ]] || cleanup_ok=0
  {
    print -r -- "cleanup_attempt=$CLEANUP_ATTEMPT"
    print -r -- "rig_removal_evidence=final-rig-removal${suffix}.txt"
    print -r -- "rig_path_after=$rig_path"
    print -r -- "rig_pid_after=$rig_pid"
    print -r -- "field_path_unchanged=$([[ "$after_field" == "$BEFORE_FIELD_PATH" ]] && print true || print false)"
    print -r -- "field_pid_unchanged=$([[ "$after_field_pid" == "$BEFORE_FIELD_PID" ]] && print true || print false)"
    print -r -- "settings_unchanged=$([[ "$after_font" == "$BEFORE_FONT_SCALE" && "$after_accel" == "$BEFORE_ACCELEROMETER_ROTATION" && "$after_rotation" == "$BEFORE_USER_ROTATION" ]] && print true || print false)"
    print -r -- "cleanup_verified=$([[ $cleanup_ok == 1 ]] && print true || print false)"
  } > "$EVIDENCE/final-cleanup${suffix}.txt"
  set -e
  if (( cleanup_ok == 1 )); then
    CURRENT_DRIVER=''
    GATE_CURRENT_DRIVER=''
    GUARDED_COMMAND_PID=''
    SOURCE_GUARD_PID=''
    BOOTSTRAP_SOURCE_GUARD_PID=''
    CLEANUP_DONE=1
    return 0
  fi
  CLEANUP_DONE=0
  return 1
}

on_exit() {
  local original_exit=$?
  local final_exit=$original_exit retain_user_temp=0
  trap - EXIT INT TERM
  set +e
  if (( CLEANUP_DONE == 0 )); then
    local cleanup_succeeded=0
    while (( CLEANUP_ATTEMPT < 2 )); do
      if cleanup_rig; then
        cleanup_succeeded=1
        break
      fi
    done
    if (( cleanup_succeeded == 0 )); then
      final_exit=1
    fi
  fi
  if ! cleanup_isolated_gradle_home; then
    final_exit=1
    retain_user_temp=1
  fi
  if ! cleanup_flutter_gradle_generated_state; then
    final_exit=1
  fi
  if {
    [[ "$SOURCE_GUARD_PID" == <-> ]] \
      && kill -0 "$SOURCE_GUARD_PID" 2>/dev/null
  } || {
    [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]] \
      && kill -0 "$BOOTSTRAP_SOURCE_GUARD_PID" 2>/dev/null
  } || (( retain_user_temp == 1 )) \
    || [[ -n ${SOURCE_GUARD_EVENTS_LIVE:-} \
      && ( -e "$SOURCE_GUARD_EVENTS_LIVE" || -L "$SOURCE_GUARD_EVENTS_LIVE" ) ]] \
    || [[ -n ${BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE:-} \
      && ( -e "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
        || -L "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" ) ]]; then
    final_exit=1
  elif ! cleanup_isolated_user_home; then
    final_exit=1
    retain_user_temp=1
  fi
  exit "$final_exit"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

GENERATOR_LOG="$EVIDENCE/fixture-generator.log"
MEASURE_LOG="$EVIDENCE/flutter-measure.log"
SAMPLES="$EVIDENCE/pss.tsv"
print -r -- $'sample_start_epoch_us\tsample_end_epoch_us\tstage\ttotal_pss_kb\tmarker_epoch_us\tpid' > "$SAMPLES"
PSS_DISCARDS="$EVIDENCE/pss-discards.tsv"
print -r -- $'sample_start_epoch_us\tsample_end_epoch_us\tpid\treason\tmarker_before\tmarker_after' \
  > "$PSS_DISCARDS"
flutter_version=$(sealed_flutter flutter-version --version --suppress-analytics | awk 'NR == 1 {print}') \
  || die "sealed Flutter version probe failed"
[[ -n "$flutter_version" ]] || die "sealed Flutter version probe was empty"
[[ "$flutter_version" == Flutter\ 3.47.0\ * && "$flutter_version" != *$'\n'* ]] \
  || die "sealed Flutter version probe was unexpected"
dart_version=$(sealed_dart dart-version --version) \
  || die "sealed Dart version probe failed"
[[ -n "$dart_version" ]] || die "sealed Dart version probe was empty"
[[ "$dart_version" == Dart\ SDK\ version:\ 3.13.0\ * \
  && "$dart_version" != *$'\n'* ]] \
  || die "sealed Dart version probe was unexpected"
{
  print -r -- "serial=$SERIAL"
  print -r -- "model=$($ADB -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
  print -r -- "android=$($ADB -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
  print -r -- "api=$($ADB -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
  print -r -- "abi=$($ADB -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"
  print -r -- "build_fingerprint=$($ADB -s "$SERIAL" shell getprop ro.build.fingerprint | tr -d '\r')"
  print -r -- "share_plus_version=$(awk '/^  share_plus:/{found=1} found && /version:/{gsub(/[\" ]/, "", $2); print $2; exit}' pubspec.lock)"
  print -r -- "pubspec_lock_sha256=$(shasum -a 256 pubspec.lock | awk '{print $1}')"
  print -r -- "flutter_executable=${FLUTTER:A}"
  print -r -- "flutter_launcher_sha256=$(shasum -a 256 "$FLUTTER" | awk '{print $1}')"
  print -r -- "flutter_execution_helper=${SEALED_SDK_EXEC:A}"
  print -r -- "flutter_tools_snapshot=${FLUTTER_TOOLS_SNAPSHOT:A}"
  print -r -- "flutter_tools_snapshot_sha256=$(shasum -a 256 "$FLUTTER_TOOLS_SNAPSHOT" | awk '{print $1}')"
  print -r -- "flutter_version=$flutter_version"
  print -r -- "dart_launcher=${DART:A}"
  print -r -- "dart_executable=${CACHED_DART:A}"
  print -r -- "dart_version=$dart_version"
  print -r -- "python_executable=${PYTHON:A}"
  print -r -- "python_executable_sha256=$PYTHON_SHA256"
  print -r -- "python_runtime_root=${PYTHON_RUNTIME_ROOT:A}"
  print -r -- "python_version=$("$PYTHON" -I -S -B --version 2>&1)"
  print -r -- "source_guard_backend=darwin-fsevents"
  print -r -- "android_sdk_sandbox_profile=${ANDROID_SDK_SANDBOX_PROFILE:A}"
  print -r -- "android_sdk_sandbox_profile_sha256=$ANDROID_SDK_SANDBOX_PROFILE_SHA256"
  print -r -- "android_sdk_sandbox_wrapper=${ANDROID_SDK_SANDBOX_EXEC:A}"
  print -r -- "android_sdk_sandbox_wrapper_sha256=$ANDROID_SDK_SANDBOX_WRAPPER_SHA256"
  print -r -- "android_sdk_sandbox_probe=${ANDROID_SDK_SANDBOX_PROBE:A}"
  print -r -- "android_sdk_sandbox_probe_sha256=$ANDROID_SDK_SANDBOX_PROBE_SHA256"
  print -r -- "android_sdk_sandbox_preflight=${ANDROID_SDK_SANDBOX_PREFLIGHT:A}"
  print -r -- "android_sdk_sandbox_preflight_sha256=$ANDROID_SDK_SANDBOX_PREFLIGHT_SHA256"
  print -r -- "android_sdk_sandbox_exec=/usr/bin/sandbox-exec"
  print -r -- "android_sdk_sandbox_exec_sha256=$ANDROID_SDK_SANDBOX_EXEC_SHA256"
  print -r -- "process_scope_helper=${PROCESS_SCOPE_HELPER:A}"
  print -r -- "process_scope_helper_sha256=$PROCESS_SCOPE_HELPER_SHA256"
  print -r -- "scoped_command_helper=${SCOPED_COMMAND:A}"
  print -r -- "scoped_command_helper_sha256=$SCOPED_COMMAND_SHA256"
  print -r -- "android_sdk_sandbox_prepare_evidence=${ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE:A}"
  print -r -- "android_sdk_sandbox_post_evidence=${ANDROID_SDK_SANDBOX_POST_EVIDENCE:A}"
  print -r -- "pub_cache_root=${SEALED_PUB_CACHE:A}"
  print -r -- "android_sdk_root=${SEALED_ANDROID_SDK_ROOT:A}"
  print -r -- "jdk_root=${SEALED_JDK_ROOT:A}"
  print -r -- "gradle_distribution_root=${GRADLE_DIST_ROOT:A}"
  print -r -- "gradle_user_home=${GRADLE_USER_HOME:A}"
  print -r -- "isolated_gradle_properties=${ISOLATED_GRADLE_PROPERTIES:A}"
  print -r -- "isolated_gradle_properties_sha256=$ISOLATED_GRADLE_PROPERTIES_SHA256"
  print -r -- "gradle_gate_c_rig_debug=true"
  print -r -- "gradle_verification_metadata_sha256=$(shasum -a 256 android/gradle/verification-metadata.xml | awk '{print $1}')"
  print -r -- "adb_executable=${ADB:A}"
  print -r -- "adb_sha256=$(shasum -a 256 "$ADB" | awk '{print $1}')"
  print -r -- "adb_version=$($ADB version | awk 'NR == 1 {print}')"
  print -r -- "isolated_flutter_settings_sha256=$(shasum -a 256 "$ISOLATED_FLUTTER_SETTINGS" | awk '{print $1}')"
  print -r -- "isolated_debug_keystore_sha256=$(shasum -a 256 "$SEALED_DEBUG_KEYSTORE" | awk '{print $1}')"
  print -r -- "head=$(git -C "$APP_ROOT" rev-parse HEAD)"
  print -r -- "package=$PACKAGE"
  print -r -- "command=tool/telemetry_memory_rig/run.sh $SERIAL"
} > "$EVIDENCE/identity.txt"
git -C "$APP_ROOT" status --short > "$EVIDENCE/git-status-short.txt"
write_tested_tree_manifest "$EVIDENCE/tested-files.pre.sha256"
assert_flutter_binding
assert_toolchain_binding
ensure_rig_absent "$EVIDENCE/initial-rig-cleanup.txt" \
  || die "rig package absence could not be proven before the initial install"

SOURCE_GUARD_STOP="$EVIDENCE/source-tree-guard.stop"
SOURCE_GUARD_READY="$EVIDENCE/source-tree-guard-ready.json"
SOURCE_GUARD_EVENTS="$EVIDENCE/source-tree-guard-events.jsonl"
SOURCE_GUARD_EVENTS_LIVE="$ISOLATED_USER_TEMP_PARENT/source-tree-guard-events.jsonl"
SOURCE_GUARD_RESULT="$EVIDENCE/source-tree-guard-result.json"
SOURCE_GUARD_BASELINE_SIDECAR="$EVIDENCE/source-tree-guard-baseline.json"
SOURCE_GUARD_LOG="$EVIDENCE/source-tree-guard.log"
for guard_path in \
  "$SOURCE_GUARD_STOP" "$SOURCE_GUARD_READY" "$SOURCE_GUARD_EVENTS" \
  "$SOURCE_GUARD_EVENTS_LIVE" \
  "$SOURCE_GUARD_RESULT" "$SOURCE_GUARD_BASELINE_SIDECAR" \
  "$SOURCE_GUARD_LOG"; do
  [[ ! -e "$guard_path" ]] \
    || die "stale source-tree guard control/evidence exists: $guard_path"
done
SOURCE_GUARD_NONCE=$("$PYTHON" -I -S -B -c 'import secrets; print(secrets.token_hex(16))')
[[ ${#SOURCE_GUARD_NONCE} == 32 && "$SOURCE_GUARD_NONCE" != *[^0-9a-f]* ]] \
  || die "could not generate the source-tree guard nonce"
SOURCE_GUARD_LAUNCHED_EPOCH_US=$("$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)')
"$PYTHON" -I -S -B "$HERE/source_tree_guard.py" \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --toolchain-root "$SEALED_ANDROID_SDK_ROOT" \
  --toolchain-root "$SEALED_JDK_ROOT" \
  --toolchain-root "$GRADLE_DIST_ROOT" \
  --toolchain-root "$ISOLATED_FLUTTER_SETTINGS" \
  --toolchain-root "$SEALED_DEBUG_KEYSTORE" \
  --toolchain-root "$PYTHON_RUNTIME_ROOT" \
  --backend darwin-fsevents \
  --stop-file "$SOURCE_GUARD_STOP" \
  --ready-file "$SOURCE_GUARD_READY" \
  --events-file "$SOURCE_GUARD_EVENTS_LIVE" \
  --result-file "$SOURCE_GUARD_RESULT" \
  --baseline-manifest "$EVIDENCE/tested-files.pre.sha256" \
  --baseline-sidecar "$SOURCE_GUARD_BASELINE_SIDECAR" \
  --nonce "$SOURCE_GUARD_NONCE" \
  > "$SOURCE_GUARD_LOG" 2>&1 &
SOURCE_GUARD_PID=$!
if wait_for_live_guard_ready "$SOURCE_GUARD_PID" "$SOURCE_GUARD_READY" \
  "$SOURCE_GUARD_READY_TIMEOUT_MS"; then
  :
else
  ready_wait_status=$?
  case $ready_wait_status in
    1) die "source-tree guard did not become ready" ;;
    2) die "source-tree guard exited before ready" ;;
    3) die "source-tree guard readiness evidence is unsafe" ;;
    127) die "source-tree guard readiness clock failed" ;;
    *) die "source-tree guard readiness wait failed" ;;
  esac
fi
"$PYTHON" -I -S -B - "$SOURCE_GUARD_READY" "$SOURCE_GUARD_NONCE" \
  "$SOURCE_GUARD_PID" "$SOURCE_GUARD_LAUNCHED_EPOCH_US" \
  "$EVIDENCE/tested-files.pre.sha256" \
  "$SOURCE_GUARD_BASELINE_SIDECAR" \
  "$SEALED_ANDROID_SDK_ROOT" "$SEALED_JDK_ROOT" "$GRADLE_DIST_ROOT" \
  "$ISOLATED_FLUTTER_SETTINGS" "$SEALED_DEBUG_KEYSTORE" \
  "$PYTHON_RUNTIME_ROOT" \
  > "$EVIDENCE/source-tree-guard-ready-validated.txt" <<'PY'
import hashlib, json, os, pathlib, stat, sys, time

path, nonce, pid_text, launched_text, baseline_text, sidecar_text, *required_roots = sys.argv[1:]
value = json.load(open(path, encoding='utf-8'))
POLICY = 'sealed-manifest-pure-item-cloned-v2'
SIDECAR_KEYS = {
    'version', 'policy', 'manifestPath', 'manifestSha256',
    'manifestEntryCount', 'uniqueRegularFileCount',
    'uniqueRegularFileBytes', 'totalXattrBytes',
    'namespaceEntryCounts', 'eventScopeFileCounts', 'records',
}
ATTESTATION_FIELDS = (
    'baselineManifestPath', 'baselineManifestSha256',
    'baselineSidecarPath', 'baselineSidecarSha256', 'baselineSidecarBytes',
    'baselineManifestEntryCount', 'baselineUniqueRegularFileCount',
    'baselineUniqueRegularFileBytes', 'baselineTotalXattrBytes',
    'baselineNamespaceEntryCounts', 'baselineEventScopeFileCounts',
)
FINGERPRINT_FIELDS = {
    'sha256', 'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size',
    'mtimeNs', 'ctimeNs', 'birthtimeNs', 'fileFlags', 'xattrs',
}
FINGERPRINT_INTEGER_FIELDS = (
    'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size', 'mtimeNs', 'ctimeNs',
)
NAMESPACES = {'local', 'package', 'flutterToolPackage', 'flutterToolchain'}
EVENT_SCOPES = {'exact-file', 'local-directory', 'external-package', 'toolchain'}
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_SIDECAR_BYTES = 64 * 1024 * 1024

def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)

def valid_fingerprint(fingerprint):
    if not isinstance(fingerprint, dict) or set(fingerprint) != FINGERPRINT_FIELDS:
        return False
    if not valid_sha256(fingerprint.get('sha256')):
        return False
    if any(type(fingerprint.get(field)) is not int or fingerprint[field] < 0 for field in FINGERPRINT_INTEGER_FIELDS):
        return False
    if (
        fingerprint['inode'] < 1
        or fingerprint['mode'] & 0o170000 != 0o100000
        or fingerprint['mode'] & 0o002
        or (
            fingerprint['mode'] & 0o020
            and fingerprint['gid'] in {os.getegid(), *os.getgroups()}
        )
        or fingerprint['linkCount'] != 1
        or fingerprint['uid'] != os.getuid()
    ):
        return False
    for field in ('birthtimeNs', 'fileFlags'):
        field_value = fingerprint.get(field)
        if field_value is not None and (type(field_value) is not int or field_value < 0):
            return False
    xattrs = fingerprint.get('xattrs')
    if not isinstance(xattrs, list):
        return False
    names = []
    for xattr in xattrs:
        name = xattr.get('name') if isinstance(xattr, dict) else None
        suffix = name[4:] if isinstance(name, str) and name.startswith('hex:') else ''
        if (
            not isinstance(xattr, dict) or set(xattr) != {'name', 'bytes', 'sha256'}
            or not suffix or len(suffix) % 2 or any(c not in '0123456789abcdef' for c in suffix)
            or type(xattr.get('bytes')) is not int or xattr['bytes'] < 0
            or not valid_sha256(xattr.get('sha256'))
        ):
            return False
        names.append(name)
    return names == sorted(names) and len(names) == len(set(names))

def safe_regular_bytes(path_text, maximum, label):
    supplied = pathlib.Path(path_text)
    if not supplied.is_absolute():
        raise SystemExit(f'{label} path is not absolute')
    try:
        canonical = supplied.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f'{label} path is unsafe: {error}') from error
    if supplied != canonical:
        raise SystemExit(f'{label} path is not canonical')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise SystemExit(f'{label} could not be opened safely: {error}') from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid != os.getuid() or before.st_mode & 0o022
            or before.st_size < 1 or before.st_size > maximum
        ):
            raise SystemExit(f'{label} metadata is unsafe')
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f'{label} exceeds byte bound')
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise SystemExit(f'{label} changed while reading')
    finally:
        os.close(descriptor)
    return canonical, b''.join(chunks)

def namespace_for(logical_id):
    if logical_id.startswith('@package/'):
        return 'package'
    if logical_id.startswith('@flutter-tool-package/'):
        return 'flutterToolPackage'
    if logical_id.startswith('@toolchain/'):
        return 'flutterToolchain'
    if logical_id.startswith('@'):
        raise SystemExit('baseline manifest namespace is unknown')
    return 'local'

def load_baseline(manifest_text, sidecar_text):
    manifest, manifest_bytes = safe_regular_bytes(manifest_text, MAX_MANIFEST_BYTES, 'baseline manifest')
    try:
        manifest_source = manifest_bytes.decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise SystemExit('baseline manifest is not strict UTF-8') from error
    manifest_entries = {}
    manifest_order = []
    for number, line in enumerate(manifest_source.splitlines(), 1):
        if len(line) < 67 or line[64:66] != '  ' or not valid_sha256(line[:64]):
            raise SystemExit(f'baseline manifest line {number} is invalid')
        logical_id = line[66:]
        pure = pathlib.PurePosixPath(logical_id)
        if (
            not logical_id or pure.is_absolute() or '..' in pure.parts
            or any(ord(c) < 32 or ord(c) == 127 for c in logical_id)
            or logical_id in manifest_entries
        ):
            raise SystemExit('baseline manifest logical ID is unsafe or duplicate')
        manifest_entries[logical_id] = (line[:64], namespace_for(logical_id))
        manifest_order.append(logical_id)
        if len(manifest_entries) > 50_000:
            raise SystemExit('baseline manifest exceeds entry bound')
    if not manifest_entries or manifest_order != sorted(manifest_order):
        raise SystemExit('baseline manifest is empty or non-canonical')
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    sidecar, sidecar_bytes = safe_regular_bytes(sidecar_text, MAX_SIDECAR_BYTES, 'baseline sidecar')
    try:
        payload = json.loads(sidecar_bytes.decode('utf-8', errors='strict'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit('baseline sidecar is invalid JSON') from error
    canonical_sidecar = (json.dumps(payload, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if sidecar_bytes != canonical_sidecar or not isinstance(payload, dict) or set(payload) != SIDECAR_KEYS:
        raise SystemExit('baseline sidecar is not canonical schema v1')
    if (
        type(payload.get('version')) is not int or payload['version'] != 1
        or payload.get('policy') != POLICY
        or payload.get('manifestPath') != str(manifest)
        or payload.get('manifestSha256') != manifest_sha
    ):
        raise SystemExit('baseline sidecar identity is invalid')
    records = payload.get('records')
    if not isinstance(records, list) or not records:
        raise SystemExit('baseline sidecar records are empty')
    records_by_path = {}
    seen_logical_ids = set()
    namespace_counts = {}
    scope_counts = {}
    unique_bytes = 0
    xattr_bytes = 0
    record_paths = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {'canonicalPath', 'eventScope', 'manifestEntries', 'fingerprint'}:
            raise SystemExit('baseline sidecar record schema is invalid')
        path_text = record.get('canonicalPath')
        try:
            canonical_path = pathlib.Path(path_text).resolve(strict=True) if isinstance(path_text, str) else None
        except (OSError, RuntimeError) as error:
            raise SystemExit('baseline sidecar canonical path is invalid') from error
        if canonical_path is None or not canonical_path.is_file() or str(canonical_path) != path_text or path_text in records_by_path:
            raise SystemExit('baseline sidecar canonical path is invalid or duplicate')
        scope = record.get('eventScope')
        entries = record.get('manifestEntries')
        fingerprint = record.get('fingerprint')
        if scope not in EVENT_SCOPES or not isinstance(entries, list) or not entries or not valid_fingerprint(fingerprint):
            raise SystemExit('baseline sidecar record content is invalid')
        logical_ids = []
        alias_digests = set()
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {'logicalId', 'namespace', 'sha256'}:
                raise SystemExit('baseline sidecar manifest entry schema is invalid')
            logical_id = entry.get('logicalId')
            expected = manifest_entries.get(logical_id)
            if (
                expected is None or logical_id in seen_logical_ids
                or entry.get('namespace') not in NAMESPACES
                or (entry.get('sha256'), entry.get('namespace')) != expected
            ):
                raise SystemExit('baseline sidecar manifest coverage is invalid')
            seen_logical_ids.add(logical_id)
            logical_ids.append(logical_id)
            alias_digests.add(entry['sha256'])
            namespace_counts[entry['namespace']] = namespace_counts.get(entry['namespace'], 0) + 1
        if logical_ids != sorted(logical_ids) or len(alias_digests) != 1 or fingerprint['sha256'] not in alias_digests:
            raise SystemExit('baseline sidecar aliases or fingerprint digest are invalid')
        records_by_path[path_text] = record
        record_paths.append(path_text)
        unique_bytes += fingerprint['size']
        xattr_bytes += sum(item['bytes'] for item in fingerprint['xattrs'])
        if unique_bytes > 4 * 1024 * 1024 * 1024 or xattr_bytes > 64 * 1024 * 1024:
            raise SystemExit('baseline sidecar aggregate bytes exceed bounds')
        scope_counts[scope] = scope_counts.get(scope, 0) + 1
    if record_paths != sorted(record_paths) or seen_logical_ids != set(manifest_entries):
        raise SystemExit('baseline sidecar record order or manifest coverage is invalid')
    expected_counts = {
        'manifestEntryCount': len(manifest_entries),
        'uniqueRegularFileCount': len(records),
        'uniqueRegularFileBytes': unique_bytes,
        'totalXattrBytes': xattr_bytes,
        'namespaceEntryCounts': dict(sorted(namespace_counts.items())),
        'eventScopeFileCounts': dict(sorted(scope_counts.items())),
    }
    for field, expected in expected_counts.items():
        actual = payload.get(field)
        if type(actual) is not type(expected) or actual != expected:
            raise SystemExit(f'baseline sidecar {field} is invalid')
    attestation = {
        'baselineManifestPath': str(manifest),
        'baselineManifestSha256': manifest_sha,
        'baselineSidecarPath': str(sidecar),
        'baselineSidecarSha256': hashlib.sha256(sidecar_bytes).hexdigest(),
        'baselineSidecarBytes': len(sidecar_bytes),
        'baselineManifestEntryCount': expected_counts['manifestEntryCount'],
        'baselineUniqueRegularFileCount': expected_counts['uniqueRegularFileCount'],
        'baselineUniqueRegularFileBytes': expected_counts['uniqueRegularFileBytes'],
        'baselineTotalXattrBytes': expected_counts['totalXattrBytes'],
        'baselineNamespaceEntryCounts': expected_counts['namespaceEntryCounts'],
        'baselineEventScopeFileCounts': expected_counts['eventScopeFileCounts'],
    }
    return records_by_path, attestation

def require_attestation(value, expected, label):
    if not isinstance(value, dict):
        raise SystemExit(f'{label} is not an object')
    for field in ATTESTATION_FIELDS:
        actual = value.get(field)
        wanted = expected[field]
        if type(actual) is not type(wanted) or actual != wanted:
            raise SystemExit(f'{label} {field} does not match sealed baseline')

records_by_path, attestation = load_baseline(baseline_text, sidecar_text)
require_attestation(value, attestation, 'source-tree guard readiness')
watch_paths = value.get('watchPaths')
native_roots = value.get('nativeFSEventsWatchRoots')
required = {str(pathlib.Path(item).resolve(strict=True)) for item in required_roots}
native_root_paths = (
    [pathlib.Path(item) for item in native_roots]
    if isinstance(native_roots, list) and all(isinstance(item, str) for item in native_roots)
    else []
)
sidecar_path = pathlib.Path(attestation['baselineSidecarPath'])
if (
    value.get('version') != 3
    or value.get('nonce') != nonce
    or value.get('watcherBackend') != 'darwin-fsevents'
    or value.get('pid') != int(pid_text)
    or type(value.get('startedEpochUs')) is not int
    or value['startedEpochUs'] < int(launched_text)
    or value['startedEpochUs'] > time.time_ns() // 1000
    or value.get('canaryCreatedObserved') is not True
    or value.get('canaryRemovedObserved') is not True
    or type(value.get('canaryWriteAttemptCount')) is not int
    or value['canaryWriteAttemptCount'] < 1
    or type(value.get('canaryDeleteAttemptCount')) is not int
    or value['canaryDeleteAttemptCount'] < 1
    or type(value.get('watcherPid')) is not int or value['watcherPid'] <= 0
    or type(value.get('suppressedInternalSinkEventCount')) is not int
    or value['suppressedInternalSinkEventCount'] < 0
    or value.get('cloneReconciliationPolicy') != POLICY
    or not isinstance(watch_paths, list) or not watch_paths
    or not required.issubset(set(watch_paths))
    or not native_root_paths
    or any(not root.is_dir() or root.resolve(strict=True) != root for root in native_root_paths)
    or any(not any(watched == root or watched.is_relative_to(root) for root in native_root_paths) for watched in map(pathlib.Path, watch_paths))
    or any(
        sidecar_path == watched or sidecar_path.is_relative_to(watched)
        for watched in map(pathlib.Path, watch_paths)
    )
):
    raise SystemExit('source-tree guard readiness identity/canary/baseline proof failed')
print(f"guard_pid={value['pid']}")
print(f"watcher_pid={value['watcherPid']}")
print(f"baseline_manifest_entries={attestation['baselineManifestEntryCount']}")
print(f"baseline_unique_files={len(records_by_path)}")
print('canary_verified=true')
PY
assert_source_guard_live
SOURCE_GUARD_REFERENCE_AUTHORITY=$(create_source_guard_reference_authority \
  source-guard "$SOURCE_GUARD_PID" "$SOURCE_GUARD_READY" \
  "$SOURCE_GUARD_NONCE" "$SOURCE_GUARD_STOP" "$SOURCE_GUARD_RESULT") \
  || die "source guard reference authority could not be sealed"
build_scope_reference_args --reference-authority \
  || die "source guard reference authorities are not active"
# The guard discards FSEvents that predate ready. Re-hash after its ready
# barrier so no bootstrap-window mutation can enter a measured build.
verify_tested_tree
assert_bootstrap_guard_live
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" write \
  --root "$APP_ROOT" \
  --manifest "$EVIDENCE/tested-files.bootstrap.post.sha256" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT"
cmp "$EVIDENCE/tested-files.bootstrap.sha256" \
  "$EVIDENCE/tested-files.bootstrap.post.sha256" \
  || die "bootstrap tested-tree pre/post manifests differ"
BOOTSTRAP_SOURCE_GUARD_STOP_BEFORE_EPOCH_US=$(
  "$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)'
)
touch "$BOOTSTRAP_SOURCE_GUARD_STOP"
BOOTSTRAP_SOURCE_GUARD_STOP_AFTER_EPOCH_US=$(
  "$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)'
)
set +e
reap_bootstrap_guard_for_handoff
bootstrap_source_guard_exit=$?
set -e
(( bootstrap_source_guard_exit == 0 )) \
  || die "bootstrap source-tree guard failed during authoritative handoff"
[[ -z "$BOOTSTRAP_SOURCE_GUARD_PID" ]] \
  || die "bootstrap source-tree guard remained alive after bounded reap"
preserve_guard_event_ledger \
  "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
  "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
  "$EVIDENCE/bootstrap-source-tree-guard-ledger-preservation.json" \
  || die "bootstrap source-tree guard ledger could not be preserved"
[[ -f "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
  && ! -L "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
  && ! -e "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" \
  && ! -L "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE" ]] \
  || die "bootstrap source-tree guard ledger preservation is incomplete"
"$PYTHON" -I -S -B - "$BOOTSTRAP_SOURCE_GUARD_RESULT" \
  "$BOOTSTRAP_SOURCE_GUARD_EVENTS" \
  "$BOOTSTRAP_SOURCE_GUARD_READY" \
  "$EVIDENCE/tested-files.bootstrap.sha256" \
  "$BOOTSTRAP_SOURCE_GUARD_BASELINE_SIDECAR" \
  "$BOOTSTRAP_SOURCE_GUARD_NONCE" \
  "$BOOTSTRAP_SOURCE_GUARD_LAUNCHED_EPOCH_US" \
  "$BOOTSTRAP_SOURCE_GUARD_STOP_BEFORE_EPOCH_US" \
  "$BOOTSTRAP_SOURCE_GUARD_STOP_AFTER_EPOCH_US" \
  > "$EVIDENCE/bootstrap-source-tree-guard-result-validated.txt" <<'PY'
import hashlib, json, os, pathlib, stat, sys

path, events_path, ready_path, baseline_text, sidecar_text, nonce, launched_text, stop_before_text, stop_after_text = sys.argv[1:]
value = json.load(open(path, encoding='utf-8'))
ready_value = json.load(open(ready_path, encoding='utf-8'))
launched = int(launched_text)
stop_before = int(stop_before_text)
stop_after = int(stop_after_text)
POLICY = 'sealed-manifest-pure-item-cloned-v2'
SIDECAR_KEYS = {
    'version', 'policy', 'manifestPath', 'manifestSha256',
    'manifestEntryCount', 'uniqueRegularFileCount',
    'uniqueRegularFileBytes', 'totalXattrBytes',
    'namespaceEntryCounts', 'eventScopeFileCounts', 'records',
}
ATTESTATION_FIELDS = (
    'baselineManifestPath', 'baselineManifestSha256',
    'baselineSidecarPath', 'baselineSidecarSha256', 'baselineSidecarBytes',
    'baselineManifestEntryCount', 'baselineUniqueRegularFileCount',
    'baselineUniqueRegularFileBytes', 'baselineTotalXattrBytes',
    'baselineNamespaceEntryCounts', 'baselineEventScopeFileCounts',
)
FINGERPRINT_FIELDS = {
    'sha256', 'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size',
    'mtimeNs', 'ctimeNs', 'birthtimeNs', 'fileFlags', 'xattrs',
}
FINGERPRINT_INTEGER_FIELDS = (
    'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size', 'mtimeNs', 'ctimeNs',
)
NAMESPACES = {'local', 'package', 'flutterToolPackage', 'flutterToolchain'}
EVENT_SCOPES = {'exact-file', 'local-directory', 'external-package', 'toolchain'}
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_SIDECAR_BYTES = 64 * 1024 * 1024

def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)

def valid_fingerprint(fingerprint):
    if not isinstance(fingerprint, dict) or set(fingerprint) != FINGERPRINT_FIELDS:
        return False
    if not valid_sha256(fingerprint.get('sha256')):
        return False
    if any(type(fingerprint.get(field)) is not int or fingerprint[field] < 0 for field in FINGERPRINT_INTEGER_FIELDS):
        return False
    if (
        fingerprint['inode'] < 1
        or fingerprint['mode'] & 0o170000 != 0o100000
        or fingerprint['mode'] & 0o002
        or (
            fingerprint['mode'] & 0o020
            and fingerprint['gid'] in {os.getegid(), *os.getgroups()}
        )
        or fingerprint['linkCount'] != 1
        or fingerprint['uid'] != os.getuid()
    ):
        return False
    for field in ('birthtimeNs', 'fileFlags'):
        field_value = fingerprint.get(field)
        if field_value is not None and (type(field_value) is not int or field_value < 0):
            return False
    xattrs = fingerprint.get('xattrs')
    if not isinstance(xattrs, list):
        return False
    names = []
    for xattr in xattrs:
        name = xattr.get('name') if isinstance(xattr, dict) else None
        suffix = name[4:] if isinstance(name, str) and name.startswith('hex:') else ''
        if (
            not isinstance(xattr, dict) or set(xattr) != {'name', 'bytes', 'sha256'}
            or not suffix or len(suffix) % 2 or any(c not in '0123456789abcdef' for c in suffix)
            or type(xattr.get('bytes')) is not int or xattr['bytes'] < 0
            or not valid_sha256(xattr.get('sha256'))
        ):
            return False
        names.append(name)
    return names == sorted(names) and len(names) == len(set(names))

def safe_regular_bytes(path_text, maximum, label):
    supplied = pathlib.Path(path_text)
    if not supplied.is_absolute():
        raise SystemExit(f'{label} path is not absolute')
    try:
        canonical = supplied.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f'{label} path is unsafe: {error}') from error
    if supplied != canonical:
        raise SystemExit(f'{label} path is not canonical')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise SystemExit(f'{label} could not be opened safely: {error}') from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid != os.getuid() or before.st_mode & 0o022
            or before.st_size < 1 or before.st_size > maximum
        ):
            raise SystemExit(f'{label} metadata is unsafe')
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f'{label} exceeds byte bound')
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise SystemExit(f'{label} changed while reading')
    finally:
        os.close(descriptor)
    return canonical, b''.join(chunks)

def namespace_for(logical_id):
    if logical_id.startswith('@package/'):
        return 'package'
    if logical_id.startswith('@flutter-tool-package/'):
        return 'flutterToolPackage'
    if logical_id.startswith('@toolchain/'):
        return 'flutterToolchain'
    if logical_id.startswith('@'):
        raise SystemExit('baseline manifest namespace is unknown')
    return 'local'

def load_baseline(manifest_text, sidecar_text):
    manifest, manifest_bytes = safe_regular_bytes(manifest_text, MAX_MANIFEST_BYTES, 'baseline manifest')
    try:
        manifest_source = manifest_bytes.decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise SystemExit('baseline manifest is not strict UTF-8') from error
    manifest_entries = {}
    manifest_order = []
    for number, line in enumerate(manifest_source.splitlines(), 1):
        if len(line) < 67 or line[64:66] != '  ' or not valid_sha256(line[:64]):
            raise SystemExit(f'baseline manifest line {number} is invalid')
        logical_id = line[66:]
        pure = pathlib.PurePosixPath(logical_id)
        if (
            not logical_id or pure.is_absolute() or '..' in pure.parts
            or any(ord(c) < 32 or ord(c) == 127 for c in logical_id)
            or logical_id in manifest_entries
        ):
            raise SystemExit('baseline manifest logical ID is unsafe or duplicate')
        manifest_entries[logical_id] = (line[:64], namespace_for(logical_id))
        manifest_order.append(logical_id)
        if len(manifest_entries) > 50_000:
            raise SystemExit('baseline manifest exceeds entry bound')
    if not manifest_entries or manifest_order != sorted(manifest_order):
        raise SystemExit('baseline manifest is empty or non-canonical')
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    sidecar, sidecar_bytes = safe_regular_bytes(sidecar_text, MAX_SIDECAR_BYTES, 'baseline sidecar')
    try:
        payload = json.loads(sidecar_bytes.decode('utf-8', errors='strict'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit('baseline sidecar is invalid JSON') from error
    canonical_sidecar = (json.dumps(payload, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if sidecar_bytes != canonical_sidecar or not isinstance(payload, dict) or set(payload) != SIDECAR_KEYS:
        raise SystemExit('baseline sidecar is not canonical schema v1')
    if (
        type(payload.get('version')) is not int or payload['version'] != 1
        or payload.get('policy') != POLICY
        or payload.get('manifestPath') != str(manifest)
        or payload.get('manifestSha256') != manifest_sha
    ):
        raise SystemExit('baseline sidecar identity is invalid')
    records = payload.get('records')
    if not isinstance(records, list) or not records:
        raise SystemExit('baseline sidecar records are empty')
    records_by_path = {}
    seen_logical_ids = set()
    namespace_counts = {}
    scope_counts = {}
    unique_bytes = 0
    xattr_bytes = 0
    record_paths = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {'canonicalPath', 'eventScope', 'manifestEntries', 'fingerprint'}:
            raise SystemExit('baseline sidecar record schema is invalid')
        path_text = record.get('canonicalPath')
        try:
            canonical_path = pathlib.Path(path_text).resolve(strict=True) if isinstance(path_text, str) else None
        except (OSError, RuntimeError) as error:
            raise SystemExit('baseline sidecar canonical path is invalid') from error
        if canonical_path is None or not canonical_path.is_file() or str(canonical_path) != path_text or path_text in records_by_path:
            raise SystemExit('baseline sidecar canonical path is invalid or duplicate')
        scope = record.get('eventScope')
        entries = record.get('manifestEntries')
        fingerprint = record.get('fingerprint')
        if scope not in EVENT_SCOPES or not isinstance(entries, list) or not entries or not valid_fingerprint(fingerprint):
            raise SystemExit('baseline sidecar record content is invalid')
        logical_ids = []
        alias_digests = set()
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {'logicalId', 'namespace', 'sha256'}:
                raise SystemExit('baseline sidecar manifest entry schema is invalid')
            logical_id = entry.get('logicalId')
            expected = manifest_entries.get(logical_id)
            if (
                expected is None or logical_id in seen_logical_ids
                or entry.get('namespace') not in NAMESPACES
                or (entry.get('sha256'), entry.get('namespace')) != expected
            ):
                raise SystemExit('baseline sidecar manifest coverage is invalid')
            seen_logical_ids.add(logical_id)
            logical_ids.append(logical_id)
            alias_digests.add(entry['sha256'])
            namespace_counts[entry['namespace']] = namespace_counts.get(entry['namespace'], 0) + 1
        if logical_ids != sorted(logical_ids) or len(alias_digests) != 1 or fingerprint['sha256'] not in alias_digests:
            raise SystemExit('baseline sidecar aliases or fingerprint digest are invalid')
        records_by_path[path_text] = record
        record_paths.append(path_text)
        unique_bytes += fingerprint['size']
        xattr_bytes += sum(item['bytes'] for item in fingerprint['xattrs'])
        if unique_bytes > 4 * 1024 * 1024 * 1024 or xattr_bytes > 64 * 1024 * 1024:
            raise SystemExit('baseline sidecar aggregate bytes exceed bounds')
        scope_counts[scope] = scope_counts.get(scope, 0) + 1
    if record_paths != sorted(record_paths) or seen_logical_ids != set(manifest_entries):
        raise SystemExit('baseline sidecar record order or manifest coverage is invalid')
    expected_counts = {
        'manifestEntryCount': len(manifest_entries),
        'uniqueRegularFileCount': len(records),
        'uniqueRegularFileBytes': unique_bytes,
        'totalXattrBytes': xattr_bytes,
        'namespaceEntryCounts': dict(sorted(namespace_counts.items())),
        'eventScopeFileCounts': dict(sorted(scope_counts.items())),
    }
    for field, expected in expected_counts.items():
        actual = payload.get(field)
        if type(actual) is not type(expected) or actual != expected:
            raise SystemExit(f'baseline sidecar {field} is invalid')
    attestation = {
        'baselineManifestPath': str(manifest),
        'baselineManifestSha256': manifest_sha,
        'baselineSidecarPath': str(sidecar),
        'baselineSidecarSha256': hashlib.sha256(sidecar_bytes).hexdigest(),
        'baselineSidecarBytes': len(sidecar_bytes),
        'baselineManifestEntryCount': expected_counts['manifestEntryCount'],
        'baselineUniqueRegularFileCount': expected_counts['uniqueRegularFileCount'],
        'baselineUniqueRegularFileBytes': expected_counts['uniqueRegularFileBytes'],
        'baselineTotalXattrBytes': expected_counts['totalXattrBytes'],
        'baselineNamespaceEntryCounts': expected_counts['namespaceEntryCounts'],
        'baselineEventScopeFileCounts': expected_counts['eventScopeFileCounts'],
    }
    return records_by_path, attestation

def require_attestation(value, expected, label):
    if not isinstance(value, dict):
        raise SystemExit(f'{label} is not an object')
    for field in ATTESTATION_FIELDS:
        actual = value.get(field)
        wanted = expected[field]
        if type(actual) is not type(wanted) or actual != wanted:
            raise SystemExit(f'{label} {field} does not match sealed baseline')

records_by_path, attestation = load_baseline(baseline_text, sidecar_text)
require_attestation(ready_value, attestation, 'source-tree guard readiness')
require_attestation(value, attestation, 'source-tree guard result')
if any(ready_value.get(field) != value.get(field) for field in ATTESTATION_FIELDS):
    raise SystemExit('source-tree guard ready/result baseline attestations differ')
termination = value.get('watcherTermination', {})
counts = {'raw-darwin-fsevents': 0, 'classified-darwin-fsevents': 0}
raw_by_key = {}
classified_by_key = {}
no_delta_records = []
violating_record_count = 0
allowed_reconciliation_statuses = {'clone-baseline-missing', 'clone-observed-delta', 'clone-observed-no-delta'}
darwin_event_flag_names = {
    0x00000001: 'MustScanSubDirs', 0x00000002: 'UserDropped', 0x00000004: 'KernelDropped',
    0x00000008: 'EventIdsWrapped', 0x00000010: 'HistoryDone', 0x00000020: 'RootChanged',
    0x00000040: 'Mount', 0x00000080: 'Unmount', 0x00000100: 'ItemCreated',
    0x00000200: 'ItemRemoved', 0x00000400: 'ItemInodeMetaMod', 0x00000800: 'ItemRenamed',
    0x00001000: 'ItemModified', 0x00002000: 'ItemFinderInfoMod', 0x00004000: 'ItemChangeOwner',
    0x00008000: 'ItemXattrMod', 0x00010000: 'ItemIsFile', 0x00020000: 'ItemIsDir',
    0x00040000: 'ItemIsSymlink', 0x00080000: 'OwnEvent', 0x00100000: 'ItemIsHardlink',
    0x00200000: 'ItemIsLastHardlink', 0x00400000: 'ItemCloned',
}
darwin_known_flag_mask = sum(darwin_event_flag_names)
darwin_integrity_names = {'MustScanSubDirs', 'UserDropped', 'KernelDropped', 'EventIdsWrapped', 'RootChanged', 'Mount', 'Unmount'}
path_material_flags = {'Created', 'Removed', 'Renamed', 'MovedFrom', 'MovedTo', 'Updated', 'Link', 'CloseWrite', 'ItemCloned', 'OwnerModified', 'AttributeModified', 'FSEventsUnspecified'}

def record_key(record):
    key = (record.get('callbackBatchSequence'), record.get('callbackRecordSequence'))
    if any(type(part) is not int or part < 1 for part in key):
        raise SystemExit('source-tree guard ledger record key is invalid')
    return key

def decode_raw_flags(raw_flags):
    if type(raw_flags) is not int or raw_flags < 0 or raw_flags & ~darwin_known_flag_mask:
        raise SystemExit('source-tree guard paired raw flags are invalid')
    native_names = {name for flag, name in darwin_event_flag_names.items() if raw_flags & flag}
    if native_names.intersection(darwin_integrity_names):
        raise SystemExit('source-tree guard paired raw flags are invalid')
    normalized = set()
    mappings = (
        ('ItemCreated', 'Created'), ('ItemRemoved', 'Removed'), ('ItemRenamed', 'Renamed'),
        ('ItemModified', 'Updated'), ('ItemChangeOwner', 'OwnerModified'), ('ItemCloned', 'ItemCloned'),
        ('ItemIsFile', 'IsFile'), ('ItemIsDir', 'IsDir'), ('ItemIsSymlink', 'IsSymLink'),
    )
    for native_name, normalized_name in mappings:
        if native_name in native_names:
            normalized.add(normalized_name)
    if native_names.intersection({'ItemInodeMetaMod', 'ItemFinderInfoMod', 'ItemXattrMod'}):
        normalized.add('AttributeModified')
    if native_names.intersection({'ItemIsHardlink', 'ItemIsLastHardlink'}):
        normalized.add('Link')
    if not normalized:
        normalized.add('FSEventsUnspecified')
    return sorted(normalized)

with open(events_path, encoding='utf-8') as stream:
    for line_number, line in enumerate(stream, 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f'source-tree guard ledger line {line_number} is invalid: {error}') from error
        record_type = record.get('recordType') if isinstance(record, dict) else None
        if record_type not in counts:
            raise SystemExit(f'source-tree guard ledger record type is invalid: {record_type!r}')
        counts[record_type] += 1
        key = record_key(record)
        target = raw_by_key if record_type == 'raw-darwin-fsevents' else classified_by_key
        if key in target:
            raise SystemExit(f'duplicate source-tree guard {record_type} record key')
        target[key] = record
        if record_type == 'classified-darwin-fsevents':
            if any(type(record.get(field)) is not bool for field in ('included', 'material', 'violates')):
                raise SystemExit('source-tree guard classified boolean field is invalid')
            if record['violates'] != (record['included'] and record['material']):
                raise SystemExit('source-tree guard classified boolean invariant failed')
            violating_record_count += int(record['violates'])
            reconciliation = record.get('cloneReconciliation')
            if reconciliation is not None and (
                not isinstance(reconciliation, dict)
                or reconciliation.get('status') not in allowed_reconciliation_statuses
                or reconciliation.get('policy') != POLICY
            ):
                raise SystemExit('source-tree guard reconciliation status is invalid')
            if isinstance(reconciliation, dict) and reconciliation.get('status') == 'clone-observed-no-delta':
                no_delta_records.append(record)
if not set(classified_by_key).issubset(raw_by_key):
    raise SystemExit('source-tree guard classified record has no raw pair')
for key, record in classified_by_key.items():
    raw = raw_by_key[key]
    normalized_flags = decode_raw_flags(raw.get('rawFlags'))
    if (
        type(raw.get('eventId')) is not int or raw['eventId'] < 0
        or raw.get('eventId') != record.get('eventId')
        or not isinstance(raw.get('path'), str) or not raw['path']
        or raw.get('path') != record.get('path')
        or record.get('flags') != normalized_flags
    ):
        raise SystemExit('source-tree guard paired record identity/flags mismatch')
    if record.get('cloneReconciliation') is None and record['material'] != bool(set(normalized_flags).intersection(path_material_flags)):
        raise SystemExit('source-tree guard classified material does not match raw flags')
for record in classified_by_key.values():
    reconciliation = record.get('cloneReconciliation')
    if reconciliation is None:
        continue
    raw = raw_by_key[record_key(record)]
    status = reconciliation.get('status')
    baseline_fingerprint = reconciliation.get('baseline')
    current_fingerprint = reconciliation.get('current')
    if (
        raw.get('rawFlags') != 0x00410000 or raw.get('eventId') != record.get('eventId')
        or raw.get('path') != record.get('path') or record.get('flags') != ['IsFile', 'ItemCloned']
        or record.get('included') is not True or reconciliation.get('policy') != POLICY
    ):
        raise SystemExit('source-tree guard clone reconciliation proof failed')
    if status == 'clone-baseline-missing':
        valid_semantics = (
            record.get('material') is True and record.get('violates') is True
            and set(reconciliation) == {'policy', 'status'}
        )
    else:
        sidecar_record = records_by_path.get(record.get('path'))
        binding_matches = (
            set(reconciliation) == {
                'policy', 'status', 'baselineCanonicalPath',
                'baselineEventScope', 'baselineManifestEntries',
                'baseline', 'current',
            }
            and sidecar_record is not None
            and record.get('scope') == sidecar_record['eventScope']
            and reconciliation.get('baselineCanonicalPath') == sidecar_record['canonicalPath']
            and reconciliation.get('baselineEventScope') == sidecar_record['eventScope']
            and reconciliation.get('baselineManifestEntries') == sidecar_record['manifestEntries']
            and baseline_fingerprint == sidecar_record['fingerprint']
        )
        if status == 'clone-observed-delta':
            valid_semantics = (
                binding_matches and record.get('material') is True and record.get('violates') is True
                and valid_fingerprint(current_fingerprint) and current_fingerprint != baseline_fingerprint
            )
        else:
            valid_semantics = (
                binding_matches and record.get('material') is False and record.get('violates') is False
                and valid_fingerprint(current_fingerprint) and current_fingerprint == baseline_fingerprint
            )
    if not valid_semantics:
        raise SystemExit('source-tree guard clone reconciliation proof failed')
raw_count = value.get('rawCallbackRecordCount')
classified_count = value.get('classifiedEventCount')
fatal_count = value.get('fatalRawRecordCount')
suppressed_count = value.get('suppressedInternalSinkEventCount')
clone_no_delta_count = value.get('cloneObservedNoDeltaEventCount')
reported_violating_count = value.get('violatingEventCount')
observed_count = value.get('observedEventCount')
bootstrap_count = value.get('bootstrapEventCount')
ready_bootstrap_count = ready_value.get('bootstrapEventCount')
if (
    any(type(item) is not int or item < 0 for item in (raw_count, classified_count, fatal_count, suppressed_count, clone_no_delta_count, reported_violating_count, observed_count, bootstrap_count, ready_bootstrap_count))
    or bootstrap_count != ready_bootstrap_count
    or observed_count != classified_count - bootstrap_count
    or raw_count != counts['raw-darwin-fsevents']
    or classified_count != counts['classified-darwin-fsevents']
    or fatal_count != len(set(raw_by_key) - set(classified_by_key))
    or clone_no_delta_count != len(no_delta_records)
    or reported_violating_count != violating_record_count
):
    raise SystemExit('source-tree guard ledger count mismatch')

if (
    value.get('version') != 3 or ready_value.get('version') != 3
    or value.get('nonce') != nonce or ready_value.get('nonce') != nonce
    or value.get('watcherBackend') != 'darwin-fsevents'
    or value.get('status') != 'stopped' or value.get('readyWritten') is not True
    or type(value.get('startedEpochUs')) is not int or value['startedEpochUs'] < launched
    or type(value.get('stopRequestedEpochUs')) is not int
    or value['stopRequestedEpochUs'] < stop_before
    or type(value.get('endedEpochUs')) is not int
    or value['stopRequestedEpochUs'] > value['endedEpochUs']
    or stop_after < stop_before
    or value.get('canaryCreatedObserved') is not True or value.get('canaryRemovedObserved') is not True
    or reported_violating_count != 0
    or value.get('cloneReconciliationPolicy') != POLICY
    or ready_value.get('cloneReconciliationPolicy') != POLICY
    or fatal_count != 0 or raw_count != classified_count
    or value.get('guardError') is not None
    or not isinstance(termination, dict)
    or termination.get('contained') is not True or termination.get('exitCode') != 0
    or termination.get('flushSyncRequested') is not True or termination.get('flushSyncCompleted') is not True
    or termination.get('drainedSentinelEmitted') is not True or termination.get('drainedSentinelObserved') is not True
):
    raise SystemExit('source-tree guard result did not prove an unchanged tree')
print(f"status={value['status']}")
print(f"observed_events={value['observedEventCount']}")
print(f"baseline_unique_files={attestation['baselineUniqueRegularFileCount']}")
print('bootstrap_unchanged_tree_verified=true')
PY

# Build the exact rig variant while the immutable source/toolchain guard is
# live, then discover only the Android components referenced by fresh model
# files emitted by that protected build. The generated models are evidence;
# their validated component list is converted to explicit immutable roots for
# every authoritative pre/post toolchain manifest.
run_guarded_command android-toolchain-build \
  "$EVIDENCE/android-toolchain-build.log" \
  "$EVIDENCE/android-toolchain-build-supervision.json" \
  "$APP_ROOT" \
  "$ANDROID_SDK_SANDBOX_EXEC" -- \
  "$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter --no-version-check \
  build apk --debug --flavor rig --no-pub --no-android-gradle-daemon \
  || die "guarded rig APK build failed during Android toolchain discovery"
verify_tested_tree
run_guarded_command android-toolchain-lint-model \
  "$EVIDENCE/android-toolchain-lint-model.log" \
  "$EVIDENCE/android-toolchain-lint-model-supervision.json" \
  "$APP_ROOT/android" \
  "$ANDROID_SDK_SANDBOX_EXEC" -- \
  ./gradlew --no-daemon :app:generateRigDebugLintModel \
  || die "guarded rig lint-model generation failed"
verify_tested_tree
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" roots \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  > "$EVIDENCE/android-toolchain.discovery.json"
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" \
  verify-native-cache-freshness \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --cleanup-evidence "$EVIDENCE/external-native-cache-cleanup.pre.json" \
  --generated-cleanup-evidence "$EVIDENCE/generated-input-cleanup.json" \
  --discovery "$EVIDENCE/android-toolchain.discovery.json" \
  --output "$EVIDENCE/native-cache-freshness-validated.json"
ANDROID_COMPONENT_LIST=$("$PYTHON" -I -S -B - "$EVIDENCE/android-toolchain.discovery.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8'))
components = value.get('components')
if not isinstance(components, list) or not components:
    raise SystemExit('Android toolchain discovery returned no components')
for component in components:
    if not isinstance(component, str) or not component or '\n' in component or '\r' in component:
        raise SystemExit('Android toolchain discovery returned an unsafe component')
    print(component)
PY
)
[[ -n "$ANDROID_COMPONENT_LIST" ]] \
  || die "Android toolchain discovery returned an empty component list"
for android_component in "${(@f)ANDROID_COMPONENT_LIST}"; do
  ANDROID_COMPONENT_ARGS+=(--component-root "$android_component")
done
(( ${#ANDROID_COMPONENT_ARGS[@]} >= 2 )) \
  || die "Android toolchain explicit component arguments were not built"
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" roots \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  "${ANDROID_COMPONENT_ARGS[@]}" \
  > "$EVIDENCE/android-toolchain.roots.json"
"$PYTHON" -I -S -B - "$EVIDENCE/android-toolchain.discovery.json" \
  "$EVIDENCE/android-toolchain.roots.json" \
  > "$EVIDENCE/android-toolchain-discovery-validated.txt" <<'PY'
import json, pathlib, re, sys
discovery = json.load(open(sys.argv[1], encoding='utf-8'))
explicit = json.load(open(sys.argv[2], encoding='utf-8'))
models = discovery.get('discoveryModels')
model_sha = discovery.get('discoveryModelSha256')
if not isinstance(models, list) or not models:
    raise SystemExit('Android toolchain discovery did not record model files')
if not isinstance(model_sha, dict) or set(model_sha) != set(models):
    raise SystemExit('Android discovery model digest coverage is incomplete')
if any(re.fullmatch(r'[0-9a-f]{64}', digest) is None for digest in model_sha.values()):
    raise SystemExit('Android discovery model digest is not canonical SHA-256')
model_paths = [pathlib.PurePath(path).as_posix() for path in models]
if not any('/lint_model/' in path for path in model_paths):
    raise SystemExit('fresh rig lint model was not included in discovery')
if not any('/cxx/' in path for path in model_paths):
    raise SystemExit('fresh rig CXX model was not included in discovery')
for key in ('sdkRoot', 'jdkRoot', 'adb', 'gradleRoot', 'components', 'watchRoots'):
    if explicit.get(key) != discovery.get(key):
        raise SystemExit(f'explicit Android toolchain binding mismatch: {key}')
if explicit.get('discoveryModels') != [] or explicit.get('discoveryModelSha256') != {}:
    raise SystemExit('explicit Android component mode unexpectedly retained discovery models')
if explicit.get('nativeCacheRoots') != [] or explicit.get('nativeModelSourcePaths') != []:
    raise SystemExit('explicit Android component mode unexpectedly retained native model paths')
print(f"components={len(explicit['components'])}")
print(f"discovery_models={len(models)}")
print('explicit_android_toolchain_roots_verified=true')
PY
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" write \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  "${ANDROID_COMPONENT_ARGS[@]}" \
  --manifest "$EVIDENCE/android-toolchain.pre.sha256"
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" verify \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  "${ANDROID_COMPONENT_ARGS[@]}" \
  --manifest "$EVIDENCE/android-toolchain.pre.sha256"
verify_tested_tree

# Generate fixtures entirely on the host with the production codec. The app
# process that will be measured cannot inherit this Dart generator heap.
HOST_FIXTURES="$EVIDENCE/host-fixtures"
sealed_dart fixture-generator tool/telemetry_memory_rig/generate_fixtures.dart \
  --output "$HOST_FIXTURES" > "$GENERATOR_LOG" 2>&1 \
  || die "host fixture generation failed; see $GENERATOR_LOG"
grep -Fq 'TELLTALE_MEMORY_HOST_FIXTURES_READY indexBytes=104857600' \
  "$GENERATOR_LOG" || die "host generator did not prove the 100 MiB index"
grep -Eq 'sessionBytes=2621[0-9]{4}' "$GENERATOR_LOG" \
  || die "host generator did not prove the near-25 MiB canonical session"
FIXTURE_ARCHIVE="$EVIDENCE/fixtures.tar"
tar -C "$HOST_FIXTURES" -cf "$FIXTURE_ARCHIVE" \
  telltale-memory-rig telltale-telemetry last-session.log \
  || die "could not archive host fixtures"
tar -tf "$FIXTURE_ARCHIVE" >/dev/null || die "host fixture archive is invalid"
[[ $(wc -c < "$FIXTURE_ARCHIVE" | tr -d ' ') -ge 131000000 ]] \
  || die "host fixture archive is unexpectedly small"
{
  print -r -- "bytes=$(wc -c < "$FIXTURE_ARCHIVE" | tr -d ' ')"
  print -r -- "sha256=$(shasum -a 256 "$FIXTURE_ARCHIVE" | awk '{print $1}')"
} > "$EVIDENCE/fixture-archive.txt"
verify_tested_tree
start_scoped_sandbox_command telemetry-memory-measure "$APP_ROOT" "$MEASURE_LOG" \
  "$ANDROID_SDK_SANDBOX_EXEC" -- \
  "$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter --no-version-check \
  test --no-pub integration_test/telemetry_memory_rig_test.dart \
  -d "$SERIAL" --flavor rig --dart-define=TELLTALE_TEST_RIG=true
test_pid=$SCOPED_COMMAND_PID
CURRENT_DRIVER=$test_pid
stage=launch
marker_epoch_us=0
last_marker=''
MEASURE_PID=''
residue_captured=0
residue_status=0
fixture_imported=0
fixture_import_status=0
for _ in {1..3600}; do
  sampling_started_ns=$(gate_c_monotonic_ns) \
    || die "monotonic sampling clock failed"
  sampling_deadline_ns=$(( sampling_started_ns + 400000000 ))
  assert_source_guard_live
  if (( fixture_imported == 0 )) && grep -Fq TELLTALE_MEMORY_FIXTURE_IMPORT_READY "$MEASURE_LOG" 2>/dev/null; then
    fixture_imported=1
    set +e
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
      tar -C app_flutter -xf - < "$FIXTURE_ARCHIVE" \
      > "$EVIDENCE/fixture-import.stdout" \
      2> "$EVIDENCE/fixture-import.stderr"
    fixture_import_status=$?
    if (( fixture_import_status == 0 )); then
      "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
        touch app_flutter/telltale-memory-rig/.host-import-complete \
        >> "$EVIDENCE/fixture-import.stdout" \
        2>> "$EVIDENCE/fixture-import.stderr"
      fixture_import_status=$?
    fi
    set -e
    if (( fixture_import_status == 0 )); then
      rm -f "$FIXTURE_ARCHIVE"
      rm -rf "$HOST_FIXTURES"
    fi
  fi

  marker=$(grep -E 'TELLTALE_MEMORY_STAGE stage=[[:alnum:]_]+ edge=(BEGIN|END) epochUs=[0-9]+' "$MEASURE_LOG" 2>/dev/null | tail -n 1 || true)
  if [[ -n "$marker" && "$marker" != "$last_marker" ]]; then
    marker_stage=$(print -r -- "$marker" | sed -E 's/.*stage=([[:alnum:]_]+).*/\1/')
    marker_edge=$(print -r -- "$marker" | sed -E 's/.*edge=(BEGIN|END).*/\1/')
    marker_epoch_us=$(print -r -- "$marker" | sed -E 's/.*epochUs=([0-9]+).*/\1/')
    stage=$([[ "$marker_edge" == BEGIN ]] && print -r -- "$marker_stage" || print -r -- idle)
    last_marker=$marker
  fi

  # A process disappearing after the integration-test driver completes is not
  # a sampling failure. Once a PID is bound, every live-driver sample remains
  # fail-closed in gate_c_adb_total_pss_sample.
  kill -0 "$test_pid" 2>/dev/null || break
  sample_marker=$last_marker
  sample_stage=$stage
  sample_marker_epoch_us=$marker_epoch_us
  if sample=$(gate_c_adb_total_pss_sample "$PACKAGE" "$MEASURE_PID"); then
    :
  elif ! kill -0 "$test_pid" 2>/dev/null; then
    # The driver completed in the sampling race; no post-completion sample is
    # required. A bound PID disappearing while the driver is live still fails.
    break
  else
    die "ADB/TOTAL PSS transaction failed during memory measurement"
  fi
  app_pid=''
  if [[ -n "$sample" ]]; then
    IFS=$'\t' read -r sample_start_epoch_us sample_end_epoch_us app_pid pss <<< "$sample"
    [[ "$sample_start_epoch_us" == <-> && "$sample_end_epoch_us" == <-> \
      && "$app_pid" == <-> && "$pss" == <-> ]] \
      || die "TOTAL PSS transaction returned a non-canonical sample"
    if [[ -z "$MEASURE_PID" ]]; then
      MEASURE_PID=$app_pid
      print -r -- "pid=$MEASURE_PID" > "$EVIDENCE/measure-process-identity.txt"
    elif [[ "$app_pid" != "$MEASURE_PID" ]]; then
      die "measured package PID changed from $MEASURE_PID to $app_pid"
    fi
    marker_after_sample=$(grep -E 'TELLTALE_MEMORY_STAGE stage=[[:alnum:]_]+ edge=(BEGIN|END) epochUs=[0-9]+' "$MEASURE_LOG" 2>/dev/null | tail -n 1 || true)
    if [[ "$marker_after_sample" == "$sample_marker" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sample_start_epoch_us" "$sample_end_epoch_us" "$sample_stage" "$pss" \
        "$sample_marker_epoch_us" "$app_pid" >> "$SAMPLES"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sample_start_epoch_us" "$sample_end_epoch_us" "$app_pid" marker-changed \
        "${sample_marker//$'\t'/ }" "${marker_after_sample//$'\t'/ }" \
        >> "$PSS_DISCARDS"
    fi
  fi

  if (( residue_captured == 0 )) && grep -Fq TELLTALE_MEMORY_RESIDUE_READY "$MEASURE_LOG" 2>/dev/null; then
    residue_captured=1
    {
      print -r -- "captured_epoch_ms=$(($(date +%s) * 1000))"
      print -r -- "pid=$app_pid"
      print -r -- "package=$PACKAGE"
      print -r -- "package_path=$($ADB -s "$SERIAL" shell pm path "$PACKAGE" | tr -d '\r')"
      "$ADB" -s "$SERIAL" shell dumpsys package "$PACKAGE" \
        | tr -d '\r' | grep -E 'versionCode=|versionName=' || true
    } > "$EVIDENCE/package-lifetime.txt"
    if [[ "$app_pid" != <-> ]]; then
      print -r -- "package process was not alive at residue marker" > "$EVIDENCE/app-files.stderr"
      residue_status=1
    else
      set +e
      "$ADB" -s "$SERIAL" shell \
        "run-as $PACKAGE find cache files -type f -exec stat -c '%n %s' '{}' ';'" \
        > "$EVIDENCE/app-files.txt" 2> "$EVIDENCE/app-files.stderr"
      residue_status=$?
      set -e
    fi
  fi

  kill -0 "$test_pid" 2>/dev/null || break
  gate_c_sleep_to_cadence "$sampling_deadline_ns" \
    || die "monotonic sampling cadence failed"
done
measurement_timed_out=0
if kill -0 "$test_pid" 2>/dev/null; then
  measurement_timed_out=1
fi
set +e
bounded_reap "$test_pid" "$EVIDENCE/measurement-driver-exit.txt" \
  measurement-driver 0 5000 5000
measurement_exit=$?
set -e
CURRENT_DRIVER=''
validate_scoped_sandbox_result telemetry-memory-measure \
  $([[ $measurement_exit == 0 ]] && print completed || print command_failed) \
  || { GRADLE_FORENSIC_RETENTION_LATCH=1; die "memory driver scope evidence failed"; }
(( measurement_timed_out == 0 )) \
  || die "device memory target exceeded the sampling timeout"
[[ $(awk -F= '/^forced_host_termination=/{print $2}' \
  "$EVIDENCE/measurement-driver-exit.txt") == none ]] \
  || die "device memory target required host termination"
if (( measurement_exit != 0 )); then
  die "device memory target failed; see $MEASURE_LOG"
fi
(( fixture_imported == 1 )) || die "measurement process never requested fixtures"
(( fixture_import_status == 0 )) || die "host fixture import failed"
(( residue_captured == 1 )) || die "residue collection window was never reached"
(( residue_status == 0 )) || die "run-as residue collection failed while package was alive"
grep -Fq TELLTALE_MEMORY_MEASURE_COMPLETE "$MEASURE_LOG" \
  || die "memory target never reached its completion marker"

"$PYTHON" -I -S -B "$HERE/analyze_pss.py" --samples "$SAMPLES" --log "$MEASURE_LOG" \
  --output "$EVIDENCE/summary.json"

# Gate C: each cut is seeded in one exact rig process, force-stopped, archived,
# uninstalled, then reconstructed in a separately installed process. The field
# package is never addressed by this runner.
GATE_TARGET=integration_test/telemetry_share_crash_rig_test.dart
GATE_DEFINE=(--flavor rig --dart-define=TELLTALE_TEST_RIG=true \
  --dart-define=TELLTALE_GATE_C_INSTRUMENTATION=true)
GATE_ROOT="$EVIDENCE/cuts"
mkdir -p "$GATE_ROOT"

gate_wait_log() {
  local log=$1 marker=$2
  for _ in {1..1200}; do
    assert_source_guard_live
    grep -Fq "$marker" "$log" 2>/dev/null && return 0
    if [[ -n ${GATE_TEST_PID:-} ]] && ! kill -0 "$GATE_TEST_PID" 2>/dev/null; then
      die "Gate C Flutter driver exited before marker: $marker ($log)"
    fi
    sleep 0.1
  done
  die "Gate C marker timed out: $marker ($log)"
}

gate_write_command() {
  local token=$1 phase=$2 cut=$3
  local json="{\"version\":1,\"runToken\":\"$token\",\"phase\":\"$phase\",\"cut\":\"$cut\"}"
  print -rn -- "$json" | "$ADB" -s "$SERIAL" shell \
    "run-as $PACKAGE sh -c 'mkdir -p cache/telltale-memory-rig-control && cat > cache/telltale-memory-rig-control/command.json.tmp && mv cache/telltale-memory-rig-control/command.json.tmp cache/telltale-memory-rig-control/command.json'"
}

gate_launch() {
  setopt localoptions errreturn
  local phase=$1 cut=$2 token=$3 log=$4
  local scope_label="gate-${(L)phase}-${(L)cut}"
  verify_tested_tree
  start_scoped_sandbox_command "$scope_label" "$APP_ROOT" "$log" \
    "$ANDROID_SDK_SANDBOX_EXEC" -- \
    "$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter --no-version-check \
    test --no-pub "$GATE_TARGET" -d "$SERIAL" "${GATE_DEFINE[@]}" \
    || die "Gate C scoped driver launch failed: $phase/$cut"
  GATE_TEST_PID=$SCOPED_COMMAND_PID
  GATE_SCOPED_LABEL=$scope_label
  GATE_CURRENT_DRIVER=$GATE_TEST_PID
  CURRENT_DRIVER=$GATE_TEST_PID
  gate_wait_log "$log" TELLTALE_GATE_C_COMMAND_READY
  gate_write_command "$token" "$phase" "$cut" \
    || die "Gate C command delivery failed: $phase/$cut"
}

gate_validate_archive() {
  local archive=$1 ack=$2 cut=$3
  "$PYTHON" -I -S -B "$HERE/gate_c_validate.py" validate \
    --archive "$archive" --ack "$ack" --cut "$cut"
}

gate_build_restore_manifest() {
  local archive=$1 ack=$2 token=$3 cut=$4 output=$5
  "$PYTHON" -I -S -B "$HERE/gate_c_validate.py" build \
    --archive "$archive" --ack "$ack" --token "$token" --cut "$cut" \
    --manifest "$output"
}

gate_revalidate_restore_bundle() {
  local archive=$1 ack=$2 token=$3 cut=$4 manifest=$5
  "$PYTHON" -I -S -B "$HERE/gate_c_validate.py" revalidate \
    --archive "$archive" --ack "$ack" --token "$token" --cut "$cut" \
    --manifest "$manifest"
}

gate_reap_seed_driver() {
  setopt localoptions no_errreturn
  local pid=$1 evidence=$2 scope_label=$3
  local helper_exit
  set +e
  bounded_reap "$pid" "$evidence" gate-seed-driver 30000 2000 2000
  helper_exit=$?
  set -e
  GATE_CURRENT_DRIVER=''
  CURRENT_DRIVER=''
  [[ $(awk -F= '/^forced_host_termination=/{print $2}' "$evidence") == none ]] \
    || die "Gate C seed driver required host TERM/KILL after force-stop"
  (( helper_exit != 0 )) || die "Gate C killed seed driver exited success"
  [[ $(awk -F= '/^outcome=/{print $2}' "$evidence") == natural_exit ]] \
    || die "Gate C seed driver did not exit after force-stop without host termination"
  validate_scoped_sandbox_result "$scope_label" command_failed \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; die "Gate C seed process scope failed"; }
}

gate_run_cut() {
  setopt localoptions errreturn
  local cut=$1
  local dir="$GATE_ROOT/$cut"
  mkdir -p "$dir"
  local token
  token=$(openssl rand -hex 16) \
    || die "Gate C token generation failed: $cut"
  [[ ${#token} == 32 && "$token" != *[^0-9a-f]* ]] \
    || die "Gate C token is invalid: $cut"
  local seed_log="$dir/seed.log"
  ensure_rig_absent "$dir/fresh-install-precondition.txt" \
    || die "rig package absence could not be proven before Gate C cut: $cut"
  gate_launch $([[ "$cut" == realPluginMirror ]] && print realPluginMirror || print seed) \
    "$cut" "$token" "$seed_log"
  local seed_pid=$GATE_TEST_PID
  local seed_scope_label=$GATE_SCOPED_LABEL
  gate_wait_log "$seed_log" "TELLTALE_GATE_C_CUT_READY token=$token cut=$cut"
  local ack_path="cache/telltale-memory-rig-control/$token-$cut-ready.json"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" cat "$ack_path" \
    > "$dir/ack.json" \
    || die "Gate C ack pull failed: $cut"
  "$PYTHON" -I -S -B -m json.tool "$dir/ack.json" >/dev/null || die "invalid Gate C ack: $cut"
  "$PYTHON" -I -S -B - "$dir/ack.json" "$token" "$cut" <<'PY'
import json, re, sys
p, token, cut = sys.argv[1:]
v = json.load(open(p, encoding='utf-8'))
required = {'version','runToken','phase','cut','id','state','sourceKind','sourceFileName','ledgerFileName','bytes','fingerprint','result','platformCalls','platformSemantic','pendingObservationMs','gateIdle','secondShareError','crossFeatureDenied'}
if set(v) != required or v['version'] != 1 or v['runToken'] != token or v['cut'] != cut:
    raise SystemExit('Gate C ack identity/schema mismatch')
ids = {'allocated':'11000000000000000000000000000001','sourceVerified':'22000000000000000000000000000002','handedOffBeforePlatform':'33000000000000000000000000000003','platformInvoked':'44000000000000000000000000000004','pendingResult':'55000000000000000000000000000005','neverResult':'66000000000000000000000000000006','realPluginMirror':'77000000000000000000000000000007'}
expected_phase = 'realPluginMirror' if cut == 'realPluginMirror' else 'seed'
if v['phase'] != expected_phase or v['id'] != ids[cut]: raise SystemExit('Gate C ack phase/id mismatch')
expected_kind = 'rawTranscript' if cut in {'allocated','sourceVerified','handedOffBeforePlatform'} else 'pidCsv'
extension = 'txt' if expected_kind == 'rawTranscript' else 'csv'
if v['sourceKind'] != expected_kind or v['sourceFileName'] != f"{v['id']}.{extension}.share" or v['ledgerFileName'] != f"{v['id']}.lease.json":
    raise SystemExit('Gate C ack group grammar mismatch')
expected_calls = 1 if cut in {'platformInvoked','pendingResult','neverResult','realPluginMirror'} else 0
if v['platformCalls'] != expected_calls: raise SystemExit('unexpected platform call count')
expected_semantic = {
    'allocated':'notInvoked',
    'sourceVerified':'notInvoked',
    'handedOffBeforePlatform':'notInvoked',
    'platformInvoked':'invokedBeforeAwait',
    'pendingResult':'completablePending',
    'neverResult':'nonCompletablePending',
    'realPluginMirror':'realPluginInvoked',
}[cut]
minimum_observation_ms = {
    'allocated':0,
    'sourceVerified':0,
    'handedOffBeforePlatform':0,
    'platformInvoked':0,
    'pendingResult':2000,
    'neverResult':5000,
    'realPluginMirror':0,
}[cut]
if v['platformSemantic'] != expected_semantic:
    raise SystemExit('unexpected platform semantic')
if type(v['pendingObservationMs']) is not int or v['pendingObservationMs'] < minimum_observation_ms:
    raise SystemExit('insufficient pending observation')
if minimum_observation_ms == 0 and v['pendingObservationMs'] != 0:
    raise SystemExit('unexpected pending observation')
if v['gateIdle'] is not False or v['secondShareError'] != 'shareBusy' or v['crossFeatureDenied'] is not True:
    raise SystemExit('Gate C ownership proof mismatch')
if cut in {'allocated','sourceVerified'}:
    if v['state'] != 'allocated' or v['result'] is not None: raise SystemExit('invalid allocated cut state')
else:
    if v['state'] != 'handedOffLease' or v['result'] != 'pending': raise SystemExit('invalid handoff cut state')
if cut != 'allocated':
    if not isinstance(v['bytes'], int) or v['bytes'] < 0: raise SystemExit('missing verified bytes')
    if not isinstance(v['fingerprint'], str) or not re.fullmatch(r'fnv1a64:[0-9a-f]{16}', v['fingerprint']):
        raise SystemExit('missing verified fingerprint')
PY
  local app_pid
  app_pid=$(gate_c_adb_required_single_pid "$PACKAGE") \
    || die "Gate C exact rig process is not alive at ack: $cut"
  local run_as_uid
  run_as_uid=$("$ADB" -s "$SERIAL" shell run-as "$PACKAGE" id -u | tr -d '\r') \
    || die "Gate C run-as UID probe failed: $cut"
  local proc_uid
  proc_uid=$("$ADB" -s "$SERIAL" shell stat -c %u "/proc/$app_pid" | tr -d '\r') \
    || die "Gate C process UID probe failed: $cut"
  [[ "$run_as_uid" == <-> && "$run_as_uid" == "$proc_uid" ]] \
    || die "Gate C PID/UID mismatch: $cut"
  local app_cmdline
  app_cmdline=$("$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    cat "/proc/$app_pid/cmdline" | tr '\0' ' ' | sed -E 's/[[:space:]]+$//') \
    || die "Gate C process cmdline probe failed: $cut"
  [[ "$app_cmdline" == *"$PACKAGE"* ]] \
    || die "Gate C process cmdline does not identify exact rig package: $cut"
  local package_path
  package_path=$("$ADB" -s "$SERIAL" shell pm path "$PACKAGE" | tr -d '\r') \
    || die "Gate C package path probe failed: $cut"
  {
    print -r -- "pid=$app_pid"
    print -r -- "uid=$run_as_uid"
    print -r -- "package=$PACKAGE"
    print -r -- "cmdline=$app_cmdline"
    print -r -- "package_path=$package_path"
    "$ADB" -s "$SERIAL" shell dumpsys package "$PACKAGE" | tr -d '\r' \
      | grep -E 'versionCode=|versionName=' | awk 'NR <= 2 {print}'
  } > "$dir/ack-process-identity.txt"
  grep -Fq "package=$PACKAGE" "$dir/ack-process-identity.txt" \
    || die "Gate C package identity capture failed"
  local source_name
  source_name=$("$PYTHON" -I -S -B -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["sourceFileName"])' \
    "$dir/ack.json") \
    || die "Gate C source filename extraction failed: $cut"
  local ledger_name
  ledger_name=$("$PYTHON" -I -S -B -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["ledgerFileName"])' \
    "$dir/ack.json") \
    || die "Gate C ledger filename extraction failed: $cut"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    cat "cache/telltale-app-shares/$ledger_name" > "$dir/pre-kill-ledger.json"
  if [[ "$cut" != allocated ]]; then
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
      cat "cache/telltale-app-shares/$source_name" > "$dir/pre-kill-source.bin"
    "$PYTHON" -I -S -B - "$dir/ack.json" "$dir/pre-kill-source.bin" > "$dir/pre-kill-source-parity.txt" <<'PY'
import json, pathlib, sys
ack = json.load(open(sys.argv[1], encoding='utf-8'))
h = 0xcbf29ce484222325
data = pathlib.Path(sys.argv[2])
n = data.stat().st_size
with data.open('rb') as source:
  while True:
    chunk = source.read(65536)
    if not chunk: break
    for b in chunk:
        h ^= b
        h = (h * 0x100000001b3) & 0xffffffffffffffff
fp = f'fnv1a64:{h:016x}'
if n != ack['bytes'] or fp != ack['fingerprint']:
    raise SystemExit(f'pre-kill source parity mismatch bytes={n} fp={fp}')
print(f'bytes={n}\nfingerprint={fp}')
PY
  fi
  "$ADB" -s "$SERIAL" shell \
    "run-as $PACKAGE sh -c \"find cache/telltale-app-shares -maxdepth 1 -type f -exec stat -c '%n %s' '{}' ';'\"" \
    > "$dir/pre-kill-app-staging.txt"
  if [[ "$cut" == realPluginMirror ]]; then
    mkdir -p "$dir/plugin-observed"
    for _ in {1..300}; do
      "$ADB" -s "$SERIAL" shell \
        "run-as $PACKAGE sh -c \"find cache/share_plus -maxdepth 1 -type f -exec stat -c '%n %s' '{}' ';'\"" \
        > "$dir/plugin-observed/listing.txt" 2>/dev/null || true
      [[ -s "$dir/plugin-observed/listing.txt" ]] && break
      sleep 0.1
    done
    [[ -s "$dir/plugin-observed/listing.txt" ]] || die "share_plus mirror not observed"
    [[ $(wc -l < "$dir/plugin-observed/listing.txt" | tr -d ' ') == 1 ]] \
      || die "share_plus mirror was not exactly one regular file"
    local plugin_name
    plugin_name=$(awk '{sub(/^.*\//, "", $1); print $1}' \
      "$dir/plugin-observed/listing.txt") \
      || die "Gate C plugin filename extraction failed: $cut"
    local live_pid
    live_pid=$(gate_c_adb_required_single_pid "$PACKAGE") \
      || die "rig PID could not be proven during plugin mirror observation"
    [[ "$live_pid" == "$app_pid" ]] \
      || die "rig PID changed before plugin mirror observation"
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
      cat "cache/telltale-app-shares/$ledger_name" \
      > "$dir/plugin-observed/ledger-at-observation.json"
    "$PYTHON" -I -S -B - "$dir/ack.json" "$dir/plugin-observed/ledger-at-observation.json" <<'PY'
import json, sys
ack = json.load(open(sys.argv[1], encoding='utf-8'))
ledger = json.load(open(sys.argv[2], encoding='utf-8'))
for key in ('id','state','sourceKind','bytes','fingerprint','result'):
    if ledger.get(key) != ack.get(key): raise SystemExit(f'plugin observation ledger mismatch: {key}')
if ledger['state'] != 'handedOffLease' or ledger['result'] != 'pending':
    raise SystemExit('plugin observation was not pending handoff')
PY
    local staged_sha
    staged_sha=$(
      "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
        sha256sum "cache/telltale-app-shares/$source_name" | awk '{print $1}' | tr -d '\r'
    ) || die "Gate C staged source hash probe failed: $cut"
    local plugin_sha
    plugin_sha=$(
      "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
        sha256sum "cache/share_plus/$plugin_name" | awk '{print $1}' | tr -d '\r'
    ) || die "Gate C plugin mirror hash probe failed: $cut"
    local staged_bytes
    staged_bytes=$("$PYTHON" -I -S -B -c \
      'import json,sys; print(json.load(open(sys.argv[1]))["bytes"])' \
      "$dir/ack.json") \
      || die "Gate C staged byte count extraction failed: $cut"
    local plugin_bytes
    plugin_bytes=$(awk '{print $2}' "$dir/plugin-observed/listing.txt") \
      || die "Gate C plugin byte count extraction failed: $cut"
    [[ "$staged_sha" == "$plugin_sha" && "$staged_bytes" == "$plugin_bytes" ]] \
      || die "share_plus mirror byte/hash parity failed"
    {
      print -r -- "staged_sha256=$staged_sha"
      print -r -- "plugin_sha256=$plugin_sha"
      print -r -- "bytes=$staged_bytes"
      print -r -- "process=$live_pid"
    } > "$dir/plugin-observed/parity.txt"
    [[ -n $(awk -F= '/^process=/{print $2}' "$dir/plugin-observed/parity.txt") ]] \
      || die "rig process died before plugin mirror observation"
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" tar -C cache -cf - share_plus \
      > "$dir/plugin-observed/mirror.tar"
    shasum -a 256 "$dir/plugin-observed/mirror.tar" > "$dir/plugin-observed/mirror.sha256"
  fi

  # Last pre-kill proof: exact process identity, ownership group, and host
  # driver must all still be live immediately before the destructive command.
  local pre_force_pid
  pre_force_pid=$(gate_c_adb_required_single_pid "$PACKAGE") \
    || die "Gate C process identity disappeared before force-stop: $cut"
  local pre_force_uid
  pre_force_uid=$("$ADB" -s "$SERIAL" shell stat -c %u "/proc/$pre_force_pid" \
    | tr -d '\r') \
    || die "Gate C pre-force-stop UID probe failed: $cut"
  local pre_force_cmdline
  pre_force_cmdline=$("$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    cat "/proc/$pre_force_pid/cmdline" | tr '\0' ' ' \
    | sed -E 's/[[:space:]]+$//') \
    || die "Gate C pre-force-stop cmdline probe failed: $cut"
  [[ "$pre_force_pid" == "$app_pid" && "$pre_force_uid" == "$run_as_uid" \
      && "$pre_force_cmdline" == "$app_cmdline" ]] \
    || die "Gate C process identity changed immediately before force-stop: $cut"
  kill -0 "$seed_pid" 2>/dev/null \
    || die "Gate C host driver exited before force-stop: $cut"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    tar -C cache -cf - telltale-app-shares > "$dir/pre-kill-app-staging.tar"
  gate_validate_archive "$dir/pre-kill-app-staging.tar" "$dir/ack.json" "$cut"
  gate_build_restore_manifest "$dir/pre-kill-app-staging.tar" \
    "$dir/ack.json" "$token" "$cut" "$dir/pre-kill-manifest.json"
  local force_before_epoch_ns
  force_before_epoch_ns=$("$PYTHON" -I -S -B -c \
    'import time; print(time.time_ns())') \
    || die "Gate C pre-force-stop timestamp failed: $cut"
  setopt no_errreturn
  set +e
  "$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE"
  local force_exit_code=$?
  set -e
  setopt errreturn
  local force_after_epoch_ns
  force_after_epoch_ns=$("$PYTHON" -I -S -B -c \
    'import time; print(time.time_ns())') \
    || die "Gate C post-force-stop timestamp failed: $cut"
  local after_force_pid
  after_force_pid=$(gate_c_adb_optional_pidof "$PACKAGE") \
    || die "Gate C post-force-stop PID absence could not be proven: $cut"
  {
    print -r -- "before_epoch_ns=$force_before_epoch_ns"
    print -r -- "command=adb -s $SERIAL shell am force-stop $PACKAGE"
    print -r -- "exit_code=$force_exit_code"
    print -r -- "after_epoch_ns=$force_after_epoch_ns"
    print -r -- "before_pid=$pre_force_pid"
    print -r -- "before_uid=$pre_force_uid"
    print -r -- "before_cmdline=$pre_force_cmdline"
    print -r -- "after_pid=$after_force_pid"
  } > "$dir/force-stop-command.txt"
  (( force_exit_code == 0 )) || die "Gate C force-stop command failed: $cut"
  (( force_after_epoch_ns >= force_before_epoch_ns )) \
    || die "Gate C force-stop timestamps were not monotonic: $cut"
  [[ -z "$after_force_pid" ]] \
    || die "Gate C force-stop failed: $cut"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    tar -C cache -cf - telltale-app-shares > "$dir/post-kill-app-staging.tar"
  shasum -a 256 "$dir/post-kill-app-staging.tar" > "$dir/post-kill-app-staging.sha256"
  tar -tvf "$dir/post-kill-app-staging.tar" > "$dir/archive-manifest.txt"
  gate_validate_archive "$dir/post-kill-app-staging.tar" "$dir/ack.json" "$cut"
  gate_build_restore_manifest "$dir/post-kill-app-staging.tar" "$dir/ack.json" \
    "$token" "$cut" "$dir/restore-manifest.json"
  "$PYTHON" -I -S -B - "$dir/pre-kill-manifest.json" "$dir/restore-manifest.json" <<'PY'
import json, sys
before, after = (json.load(open(path, encoding='utf-8')) for path in sys.argv[1:])
for key in ('sourceSha256', 'ledgerSha256', 'sourceBytes', 'sourceFingerprint'):
    if before[key] != after[key]:
        raise SystemExit(f'Gate C pre/post-kill file parity mismatch: {key}')
PY
  "$PYTHON" -I -S -B - "$dir/restore-manifest.json" > "$dir/post-kill-files.sha256" <<'PY'
import json, sys
v=json.load(open(sys.argv[1]))
print(v['sourceSha256']+'  '+v['sourceFileName'])
print(v['ledgerSha256']+'  '+v['ledgerFileName'])
PY
  gate_reap_seed_driver "$seed_pid" "$dir/seed-driver-exit.txt" \
    "$seed_scope_label"

  if [[ "$cut" != allocated && "$cut" != sourceVerified ]]; then
    "$PYTHON" -I -S -B - "$dir/pre-kill-ledger.json" <<'PY'
import datetime, json, sys
v = json.load(open(sys.argv[1], encoding='utf-8'))
eligible = datetime.datetime.fromisoformat(v['cleanupEligibleAtUtc'].replace('Z', '+00:00'))
margin = (eligible - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
if margin < 120: raise SystemExit(f'cleanup eligibility margin too small: {margin:.1f}s')
print(f'cleanup_margin_seconds={margin:.1f}')
PY
  fi

  "$ADB" -s "$SERIAL" uninstall "$PACKAGE" >/dev/null \
    || die "Gate C uninstall failed: $cut"
  local recovery_log="$dir/recovery.log"
  gate_launch recover "$cut" "$token" "$recovery_log"
  local recovery_pid=$GATE_TEST_PID
  local recovery_scope_label=$GATE_SCOPED_LABEL
  gate_wait_log "$recovery_log" "TELLTALE_GATE_C_RESTORE_READY token=$token"
  local recovery_app_pid
  recovery_app_pid=$(gate_c_adb_required_single_pid "$PACKAGE") \
    || die "Gate C recovery rig process is not alive: $cut"
  local recovery_run_as_uid
  recovery_run_as_uid=$("$ADB" -s "$SERIAL" shell run-as "$PACKAGE" id -u \
    | tr -d '\r') \
    || die "Gate C recovery run-as UID probe failed: $cut"
  local recovery_proc_uid
  recovery_proc_uid=$("$ADB" -s "$SERIAL" shell stat -c %u "/proc/$recovery_app_pid" \
    | tr -d '\r') \
    || die "Gate C recovery process UID probe failed: $cut"
  local recovery_cmdline
  recovery_cmdline=$("$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    cat "/proc/$recovery_app_pid/cmdline" | tr '\0' ' ' \
    | sed -E 's/[[:space:]]+$//') \
    || die "Gate C recovery process cmdline probe failed: $cut"
  [[ "$recovery_run_as_uid" == <-> && "$recovery_run_as_uid" == "$recovery_proc_uid" \
      && "$recovery_cmdline" == *"$PACKAGE"* ]] \
    || die "Gate C recovery PID/UID/package identity mismatch: $cut"
  local recovery_package_path
  recovery_package_path=$("$ADB" -s "$SERIAL" shell pm path "$PACKAGE" | tr -d '\r') \
    || die "Gate C recovery package path probe failed: $cut"
  {
    print -r -- "pid=$recovery_app_pid"
    print -r -- "uid=$recovery_run_as_uid"
    print -r -- "package=$PACKAGE"
    print -r -- "cmdline=$recovery_cmdline"
    print -r -- "package_path=$recovery_package_path"
  } > "$dir/recovery-process-identity.txt"
  gate_revalidate_restore_bundle "$dir/post-kill-app-staging.tar" \
    "$dir/ack.json" "$token" "$cut" "$dir/restore-manifest.json"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" tar -C cache -xf - \
    < "$dir/post-kill-app-staging.tar"
  cat "$dir/restore-manifest.json" | "$ADB" -s "$SERIAL" shell \
    "run-as $PACKAGE sh -c 'cat > cache/telltale-memory-rig-control/$token-restore-manifest.json.tmp && mv cache/telltale-memory-rig-control/$token-restore-manifest.json.tmp cache/telltale-memory-rig-control/$token-restore-manifest.json'"
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    touch "cache/telltale-memory-rig-control/$token-restore-complete"
  gate_wait_log "$recovery_log" "TELLTALE_GATE_C_RECOVERY_VERIFIED token=$token cut=$cut"
  "$ADB" -s "$SERIAL" shell \
    "run-as $PACKAGE sh -c \"find cache/telltale-app-shares -maxdepth 1 -type f -exec stat -c '%n %s' '{}' ';'\"" \
    > "$dir/post-recovery-app-staging.txt" \
    2> "$dir/post-recovery-app-staging.stderr" \
    || die "Gate C recovery inventory probe failed: $cut"
  [[ ! -s "$dir/post-recovery-app-staging.stderr" ]] \
    || die "Gate C recovery inventory probe emitted stderr: $cut"
  LC_ALL=C sort "$dir/post-recovery-app-staging.txt" \
    > "$dir/post-recovery-inventory.canonical"
  shasum -a 256 "$dir/post-recovery-inventory.canonical" \
    > "$dir/post-recovery-inventory.sha256"
  if [[ "$cut" == allocated || "$cut" == sourceVerified ]]; then
    [[ ! -s "$dir/post-recovery-app-staging.txt" ]] \
      || die "Gate C fresh root retained a never-handed-off group: $cut"
    [[ $(awk '{print $1}' "$dir/post-recovery-inventory.sha256") == \
      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] \
      || die "Gate C cleaned inventory hash was not canonical empty: $cut"
  else
    [[ $(wc -l < "$dir/post-recovery-app-staging.txt" | tr -d ' ') == 2 ]] \
      || die "Gate C retained group topology mismatch after recovery: $cut"
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
      cat "cache/telltale-app-shares/$ledger_name" > "$dir/post-recovery-ledger.json"
    "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
      cat "cache/telltale-app-shares/$source_name" > "$dir/post-recovery-source.bin"
    cmp "$dir/pre-kill-ledger.json" "$dir/post-recovery-ledger.json" \
      || die "Gate C recovered ledger changed: $cut"
    cmp "$dir/pre-kill-source.bin" "$dir/post-recovery-source.bin" \
      || die "Gate C recovered source changed: $cut"
    shasum -a 256 "$dir/post-recovery-ledger.json" \
      "$dir/post-recovery-source.bin" > "$dir/post-recovery.sha256"
    "$PYTHON" -I -S -B - "$dir/ack.json" "$dir/post-recovery-source.bin" > "$dir/post-recovery-fnv.txt" <<'PY'
import json, pathlib, sys
ack = json.load(open(sys.argv[1], encoding='utf-8'))
h = 0xcbf29ce484222325
data = pathlib.Path(sys.argv[2])
with data.open('rb') as source:
    while True:
        chunk = source.read(65536)
        if not chunk: break
        for b in chunk:
            h ^= b
            h = (h * 0x100000001b3) & 0xffffffffffffffff
fp = f'fnv1a64:{h:016x}'
if data.stat().st_size != ack['bytes'] or fp != ack['fingerprint']:
    raise SystemExit('post-recovery source parity mismatch')
print(f'bytes={data.stat().st_size}\nfingerprint={fp}')
PY
  fi
  "$ADB" -s "$SERIAL" shell run-as "$PACKAGE" \
    touch "cache/telltale-memory-rig-control/$token-capture-complete"
  setopt no_errreturn
  set +e
  bounded_reap "$recovery_pid" "$dir/recovery-driver-exit.txt" \
    gate-recovery-driver 120000 5000 5000
  local recovery_exit=$?
  set -e
  setopt errreturn
  GATE_CURRENT_DRIVER=''
  CURRENT_DRIVER=''
  [[ $(awk -F= '/^forced_host_termination=/{print $2}' \
    "$dir/recovery-driver-exit.txt") == none ]] \
    || die "Gate C recovery required host TERM/KILL: $cut"
  (( recovery_exit == 0 )) \
    || die "Gate C recovery failed: $cut ($recovery_log)"
  validate_scoped_sandbox_result "$recovery_scope_label" completed \
    || { GRADLE_FORENSIC_RETENTION_LATCH=1; die "Gate C recovery process scope failed"; }
  "$PYTHON" -I -S -B - "$dir/restore-manifest.json" \
    "$dir/post-recovery-inventory.sha256" "$dir/reconstruction.json" <<'PY'
import json, pathlib, sys
manifest=json.load(open(sys.argv[1]))
inventory_sha=pathlib.Path(sys.argv[2]).read_text().split()[0]
out={
  'version':1,
  'runToken':manifest['runToken'],
  'cut':manifest['cut'],
  'archiveSha256':manifest['archiveSha256'],
  'sourceSha256':manifest['sourceSha256'],
  'ledgerSha256':manifest['ledgerSha256'],
  'platformCalls':manifest['platformCalls'],
  'platformSemantic':manifest['platformSemantic'],
  'pendingObservationMs':manifest['pendingObservationMs'],
  'postRecoveryInventorySha256':inventory_sha,
  'classification':'cleaned' if manifest['cut'] in {'allocated','sourceVerified'} else 'retained',
  'verified':True,
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(out,sort_keys=True,separators=(',',':'))+'\n')
PY
}

GATE_CUTS=(
  allocated
  sourceVerified
  handedOffBeforePlatform
  platformInvoked
  pendingResult
  neverResult
  realPluginMirror
)
for gate_cut in "${GATE_CUTS[@]}"; do
  gate_run_cut "$gate_cut" \
    || die "Gate C cut failed: $gate_cut"
done
GATE_CURRENT_DRIVER=''
CURRENT_DRIVER=''

assert_source_guard_live
assert_android_sdk_sandbox_binding
"$PYTHON" -I -S -B "$ANDROID_SDK_SANDBOX_PREFLIGHT" verify \
  --prepared-evidence "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
  --expected-prepared-sha256 "$ANDROID_SDK_SANDBOX_PREPARED_SHA256" \
  --output "$ANDROID_SDK_SANDBOX_POST_EVIDENCE"
"$PYTHON" -I -S -B - \
  "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE" \
  "$ANDROID_SDK_SANDBOX_POST_EVIDENCE" \
  "$ANDROID_SDK_SANDBOX_PREPARED_SHA256" \
  > "$EVIDENCE/android-sdk-sandbox.post-validated.txt" <<'PY'
import hashlib, json, pathlib, sys

prepared_path = pathlib.Path(sys.argv[1])
post_path = pathlib.Path(sys.argv[2])
expected_prepared_sha256 = sys.argv[3]
prepared_bytes = prepared_path.read_bytes()
prepared = json.loads(prepared_bytes)
post = json.loads(post_path.read_text(encoding='utf-8'))
if set(post) != {
    'version', 'status', 'preparedEvidenceSha256', 'paths', 'components',
    'sandboxExec', 'androidSdk', 'sessionProof',
}:
    raise SystemExit('Android SDK sandbox post evidence schema is invalid')
if (
    post.get('version') != 1
    or post.get('status') != 'verified'
    or hashlib.sha256(prepared_bytes).hexdigest() != expected_prepared_sha256
    or post.get('preparedEvidenceSha256') != expected_prepared_sha256
    or any(
        post.get(field) != prepared.get(field)
        for field in (
            'paths', 'components', 'sandboxExec', 'androidSdk', 'sessionProof'
        )
    )
):
    raise SystemExit('Android SDK sandbox post attestation did not bind preparation')
print('android_sdk_sandbox_post_verified=true')
PY
{
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PROFILE"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_EXEC"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PROBE"
  shasum -a 256 "$ANDROID_SDK_SANDBOX_PREFLIGHT"
  shasum -a 256 /usr/bin/sandbox-exec
  shasum -a 256 "$PROCESS_SCOPE_HELPER"
  shasum -a 256 "$SCOPED_COMMAND"
} > "$EVIDENCE/android-sdk-sandbox-components.post.sha256"
cmp "$EVIDENCE/android-sdk-sandbox-components.pre.sha256" \
  "$EVIDENCE/android-sdk-sandbox-components.post.sha256" \
  || die "Android SDK sandbox component pre/post hashes differ"
assert_source_guard_live
cleanup_flutter_gradle_generated_state \
  "$EVIDENCE/flutter-gradle-generated-cleanup.post.json" \
  || die "Flutter Gradle generated state could not be removed safely"
assert_source_guard_live
"$PYTHON" -I -S -B "$HERE/tree_manifest.py" \
  clean-external-native-caches \
  --root "$APP_ROOT" \
  --expected-flutter-root "$SEALED_FLUTTER_ROOT" \
  --evidence "$EVIDENCE/external-native-cache-cleanup.post.json"
verify_tested_tree
write_tested_tree_manifest "$EVIDENCE/tested-files.post.sha256"
cmp "$EVIDENCE/tested-files.pre.sha256" "$EVIDENCE/tested-files.post.sha256" \
  || die "tested tree pre/post manifests differ"
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" roots \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  "${ANDROID_COMPONENT_ARGS[@]}" \
  > "$EVIDENCE/android-toolchain.roots.post.json"
cmp "$EVIDENCE/android-toolchain.roots.json" "$EVIDENCE/android-toolchain.roots.post.json" \
  || die "Android toolchain explicit roots changed during the live rig"
"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" write \
  "${ANDROID_TOOLCHAIN_COMMON_ARGS[@]}" \
  "${ANDROID_COMPONENT_ARGS[@]}" \
  --manifest "$EVIDENCE/android-toolchain.post.sha256"
cmp "$EVIDENCE/android-toolchain.pre.sha256" "$EVIDENCE/android-toolchain.post.sha256" \
  || die "Android toolchain pre/post manifests differ"
shasum -a 256 "$ISOLATED_FLUTTER_SETTINGS" \
  > "$EVIDENCE/flutter-settings.post.sha256"
cmp "$EVIDENCE/flutter-settings.pre.sha256" \
  "$EVIDENCE/flutter-settings.post.sha256" \
  || die "isolated Flutter settings pre/post hashes differ"
shasum -a 256 "$SEALED_DEBUG_KEYSTORE" \
  > "$EVIDENCE/android-debug-keystore.post.sha256"
cmp "$EVIDENCE/android-debug-keystore.pre.sha256" \
  "$EVIDENCE/android-debug-keystore.post.sha256" \
  || die "isolated Android debug keystore pre/post hashes differ"
shasum -a 256 "$PYTHON" > "$EVIDENCE/python-executable.post.sha256"
cmp "$EVIDENCE/python-executable.pre.sha256" \
  "$EVIDENCE/python-executable.post.sha256" \
  || die "bound Python executable pre/post hashes differ"
assert_source_guard_live
SOURCE_GUARD_STOP_BEFORE_EPOCH_US=$("$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)')
touch "$SOURCE_GUARD_STOP"
SOURCE_GUARD_STOP_AFTER_EPOCH_US=$("$PYTHON" -I -S -B -c 'import time; print(time.time_ns() // 1000)')
set +e
bounded_reap "$SOURCE_GUARD_PID" "$EVIDENCE/source-tree-guard-exit.txt" \
  source-tree-guard 10000 2000 2000
source_guard_exit=$?
set -e
(( source_guard_exit == 0 )) \
  || die "source-tree guard failed; see source-tree-guard-result.json"
! kill -0 "$SOURCE_GUARD_PID" 2>/dev/null \
  || die "source-tree guard remained alive after bounded reap"
SOURCE_GUARD_PID=''
preserve_guard_event_ledger \
  "$SOURCE_GUARD_EVENTS_LIVE" "$SOURCE_GUARD_EVENTS" \
  "$EVIDENCE/source-tree-guard-ledger-preservation.json" \
  || die "source-tree guard ledger could not be preserved"
[[ -f "$SOURCE_GUARD_EVENTS" && ! -L "$SOURCE_GUARD_EVENTS" \
  && ! -e "$SOURCE_GUARD_EVENTS_LIVE" \
  && ! -L "$SOURCE_GUARD_EVENTS_LIVE" ]] \
  || die "source-tree guard ledger preservation is incomplete"
"$PYTHON" -I -S -B - "$SOURCE_GUARD_RESULT" "$SOURCE_GUARD_EVENTS" \
  "$SOURCE_GUARD_READY" \
  "$EVIDENCE/tested-files.pre.sha256" \
  "$SOURCE_GUARD_BASELINE_SIDECAR" \
  "$SOURCE_GUARD_NONCE" \
  "$SOURCE_GUARD_LAUNCHED_EPOCH_US" "$SOURCE_GUARD_STOP_BEFORE_EPOCH_US" \
  "$SOURCE_GUARD_STOP_AFTER_EPOCH_US" \
> "$EVIDENCE/source-tree-guard-result-validated.txt" <<'PY'
import hashlib, json, os, pathlib, stat, sys

path, events_path, ready_path, baseline_text, sidecar_text, nonce, launched_text, stop_before_text, stop_after_text = sys.argv[1:]
value = json.load(open(path, encoding='utf-8'))
ready_value = json.load(open(ready_path, encoding='utf-8'))
launched = int(launched_text)
stop_before = int(stop_before_text)
stop_after = int(stop_after_text)
POLICY = 'sealed-manifest-pure-item-cloned-v2'
SIDECAR_KEYS = {
    'version', 'policy', 'manifestPath', 'manifestSha256',
    'manifestEntryCount', 'uniqueRegularFileCount',
    'uniqueRegularFileBytes', 'totalXattrBytes',
    'namespaceEntryCounts', 'eventScopeFileCounts', 'records',
}
ATTESTATION_FIELDS = (
    'baselineManifestPath', 'baselineManifestSha256',
    'baselineSidecarPath', 'baselineSidecarSha256', 'baselineSidecarBytes',
    'baselineManifestEntryCount', 'baselineUniqueRegularFileCount',
    'baselineUniqueRegularFileBytes', 'baselineTotalXattrBytes',
    'baselineNamespaceEntryCounts', 'baselineEventScopeFileCounts',
)
FINGERPRINT_FIELDS = {
    'sha256', 'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size',
    'mtimeNs', 'ctimeNs', 'birthtimeNs', 'fileFlags', 'xattrs',
}
FINGERPRINT_INTEGER_FIELDS = (
    'device', 'inode', 'mode', 'linkCount', 'uid', 'gid', 'size', 'mtimeNs', 'ctimeNs',
)
NAMESPACES = {'local', 'package', 'flutterToolPackage', 'flutterToolchain'}
EVENT_SCOPES = {'exact-file', 'local-directory', 'external-package', 'toolchain'}
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_SIDECAR_BYTES = 64 * 1024 * 1024

def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)

def valid_fingerprint(fingerprint):
    if not isinstance(fingerprint, dict) or set(fingerprint) != FINGERPRINT_FIELDS:
        return False
    if not valid_sha256(fingerprint.get('sha256')):
        return False
    if any(type(fingerprint.get(field)) is not int or fingerprint[field] < 0 for field in FINGERPRINT_INTEGER_FIELDS):
        return False
    if (
        fingerprint['inode'] < 1
        or fingerprint['mode'] & 0o170000 != 0o100000
        or fingerprint['mode'] & 0o002
        or (
            fingerprint['mode'] & 0o020
            and fingerprint['gid'] in {os.getegid(), *os.getgroups()}
        )
        or fingerprint['linkCount'] != 1
        or fingerprint['uid'] != os.getuid()
    ):
        return False
    for field in ('birthtimeNs', 'fileFlags'):
        field_value = fingerprint.get(field)
        if field_value is not None and (type(field_value) is not int or field_value < 0):
            return False
    xattrs = fingerprint.get('xattrs')
    if not isinstance(xattrs, list):
        return False
    names = []
    for xattr in xattrs:
        name = xattr.get('name') if isinstance(xattr, dict) else None
        suffix = name[4:] if isinstance(name, str) and name.startswith('hex:') else ''
        if (
            not isinstance(xattr, dict) or set(xattr) != {'name', 'bytes', 'sha256'}
            or not suffix or len(suffix) % 2 or any(c not in '0123456789abcdef' for c in suffix)
            or type(xattr.get('bytes')) is not int or xattr['bytes'] < 0
            or not valid_sha256(xattr.get('sha256'))
        ):
            return False
        names.append(name)
    return names == sorted(names) and len(names) == len(set(names))

def safe_regular_bytes(path_text, maximum, label):
    supplied = pathlib.Path(path_text)
    if not supplied.is_absolute():
        raise SystemExit(f'{label} path is not absolute')
    try:
        canonical = supplied.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f'{label} path is unsafe: {error}') from error
    if supplied != canonical:
        raise SystemExit(f'{label} path is not canonical')
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise SystemExit(f'{label} could not be opened safely: {error}') from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid != os.getuid() or before.st_mode & 0o022
            or before.st_size < 1 or before.st_size > maximum
        ):
            raise SystemExit(f'{label} metadata is unsafe')
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f'{label} exceeds byte bound')
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise SystemExit(f'{label} changed while reading')
    finally:
        os.close(descriptor)
    return canonical, b''.join(chunks)

def namespace_for(logical_id):
    if logical_id.startswith('@package/'):
        return 'package'
    if logical_id.startswith('@flutter-tool-package/'):
        return 'flutterToolPackage'
    if logical_id.startswith('@toolchain/'):
        return 'flutterToolchain'
    if logical_id.startswith('@'):
        raise SystemExit('baseline manifest namespace is unknown')
    return 'local'

def load_baseline(manifest_text, sidecar_text):
    manifest, manifest_bytes = safe_regular_bytes(manifest_text, MAX_MANIFEST_BYTES, 'baseline manifest')
    try:
        manifest_source = manifest_bytes.decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise SystemExit('baseline manifest is not strict UTF-8') from error
    manifest_entries = {}
    manifest_order = []
    for number, line in enumerate(manifest_source.splitlines(), 1):
        if len(line) < 67 or line[64:66] != '  ' or not valid_sha256(line[:64]):
            raise SystemExit(f'baseline manifest line {number} is invalid')
        logical_id = line[66:]
        pure = pathlib.PurePosixPath(logical_id)
        if (
            not logical_id or pure.is_absolute() or '..' in pure.parts
            or any(ord(c) < 32 or ord(c) == 127 for c in logical_id)
            or logical_id in manifest_entries
        ):
            raise SystemExit('baseline manifest logical ID is unsafe or duplicate')
        manifest_entries[logical_id] = (line[:64], namespace_for(logical_id))
        manifest_order.append(logical_id)
        if len(manifest_entries) > 50_000:
            raise SystemExit('baseline manifest exceeds entry bound')
    if not manifest_entries or manifest_order != sorted(manifest_order):
        raise SystemExit('baseline manifest is empty or non-canonical')
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    sidecar, sidecar_bytes = safe_regular_bytes(sidecar_text, MAX_SIDECAR_BYTES, 'baseline sidecar')
    try:
        payload = json.loads(sidecar_bytes.decode('utf-8', errors='strict'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit('baseline sidecar is invalid JSON') from error
    canonical_sidecar = (json.dumps(payload, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if sidecar_bytes != canonical_sidecar or not isinstance(payload, dict) or set(payload) != SIDECAR_KEYS:
        raise SystemExit('baseline sidecar is not canonical schema v1')
    if (
        type(payload.get('version')) is not int or payload['version'] != 1
        or payload.get('policy') != POLICY
        or payload.get('manifestPath') != str(manifest)
        or payload.get('manifestSha256') != manifest_sha
    ):
        raise SystemExit('baseline sidecar identity is invalid')
    records = payload.get('records')
    if not isinstance(records, list) or not records:
        raise SystemExit('baseline sidecar records are empty')
    records_by_path = {}
    seen_logical_ids = set()
    namespace_counts = {}
    scope_counts = {}
    unique_bytes = 0
    xattr_bytes = 0
    record_paths = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {'canonicalPath', 'eventScope', 'manifestEntries', 'fingerprint'}:
            raise SystemExit('baseline sidecar record schema is invalid')
        path_text = record.get('canonicalPath')
        try:
            canonical_path = pathlib.Path(path_text).resolve(strict=True) if isinstance(path_text, str) else None
        except (OSError, RuntimeError) as error:
            raise SystemExit('baseline sidecar canonical path is invalid') from error
        if canonical_path is None or not canonical_path.is_file() or str(canonical_path) != path_text or path_text in records_by_path:
            raise SystemExit('baseline sidecar canonical path is invalid or duplicate')
        scope = record.get('eventScope')
        entries = record.get('manifestEntries')
        fingerprint = record.get('fingerprint')
        if scope not in EVENT_SCOPES or not isinstance(entries, list) or not entries or not valid_fingerprint(fingerprint):
            raise SystemExit('baseline sidecar record content is invalid')
        logical_ids = []
        alias_digests = set()
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {'logicalId', 'namespace', 'sha256'}:
                raise SystemExit('baseline sidecar manifest entry schema is invalid')
            logical_id = entry.get('logicalId')
            expected = manifest_entries.get(logical_id)
            if (
                expected is None or logical_id in seen_logical_ids
                or entry.get('namespace') not in NAMESPACES
                or (entry.get('sha256'), entry.get('namespace')) != expected
            ):
                raise SystemExit('baseline sidecar manifest coverage is invalid')
            seen_logical_ids.add(logical_id)
            logical_ids.append(logical_id)
            alias_digests.add(entry['sha256'])
            namespace_counts[entry['namespace']] = namespace_counts.get(entry['namespace'], 0) + 1
        if logical_ids != sorted(logical_ids) or len(alias_digests) != 1 or fingerprint['sha256'] not in alias_digests:
            raise SystemExit('baseline sidecar aliases or fingerprint digest are invalid')
        records_by_path[path_text] = record
        record_paths.append(path_text)
        unique_bytes += fingerprint['size']
        xattr_bytes += sum(item['bytes'] for item in fingerprint['xattrs'])
        if unique_bytes > 4 * 1024 * 1024 * 1024 or xattr_bytes > 64 * 1024 * 1024:
            raise SystemExit('baseline sidecar aggregate bytes exceed bounds')
        scope_counts[scope] = scope_counts.get(scope, 0) + 1
    if record_paths != sorted(record_paths) or seen_logical_ids != set(manifest_entries):
        raise SystemExit('baseline sidecar record order or manifest coverage is invalid')
    expected_counts = {
        'manifestEntryCount': len(manifest_entries),
        'uniqueRegularFileCount': len(records),
        'uniqueRegularFileBytes': unique_bytes,
        'totalXattrBytes': xattr_bytes,
        'namespaceEntryCounts': dict(sorted(namespace_counts.items())),
        'eventScopeFileCounts': dict(sorted(scope_counts.items())),
    }
    for field, expected in expected_counts.items():
        actual = payload.get(field)
        if type(actual) is not type(expected) or actual != expected:
            raise SystemExit(f'baseline sidecar {field} is invalid')
    attestation = {
        'baselineManifestPath': str(manifest),
        'baselineManifestSha256': manifest_sha,
        'baselineSidecarPath': str(sidecar),
        'baselineSidecarSha256': hashlib.sha256(sidecar_bytes).hexdigest(),
        'baselineSidecarBytes': len(sidecar_bytes),
        'baselineManifestEntryCount': expected_counts['manifestEntryCount'],
        'baselineUniqueRegularFileCount': expected_counts['uniqueRegularFileCount'],
        'baselineUniqueRegularFileBytes': expected_counts['uniqueRegularFileBytes'],
        'baselineTotalXattrBytes': expected_counts['totalXattrBytes'],
        'baselineNamespaceEntryCounts': expected_counts['namespaceEntryCounts'],
        'baselineEventScopeFileCounts': expected_counts['eventScopeFileCounts'],
    }
    return records_by_path, attestation

def require_attestation(value, expected, label):
    if not isinstance(value, dict):
        raise SystemExit(f'{label} is not an object')
    for field in ATTESTATION_FIELDS:
        actual = value.get(field)
        wanted = expected[field]
        if type(actual) is not type(wanted) or actual != wanted:
            raise SystemExit(f'{label} {field} does not match sealed baseline')

records_by_path, attestation = load_baseline(baseline_text, sidecar_text)
require_attestation(ready_value, attestation, 'source-tree guard readiness')
require_attestation(value, attestation, 'source-tree guard result')
if any(ready_value.get(field) != value.get(field) for field in ATTESTATION_FIELDS):
    raise SystemExit('source-tree guard ready/result baseline attestations differ')
termination = value.get('watcherTermination', {})
counts = {'raw-darwin-fsevents': 0, 'classified-darwin-fsevents': 0}
raw_by_key = {}
classified_by_key = {}
no_delta_records = []
violating_record_count = 0
allowed_reconciliation_statuses = {'clone-baseline-missing', 'clone-observed-delta', 'clone-observed-no-delta'}
darwin_event_flag_names = {
    0x00000001: 'MustScanSubDirs', 0x00000002: 'UserDropped', 0x00000004: 'KernelDropped',
    0x00000008: 'EventIdsWrapped', 0x00000010: 'HistoryDone', 0x00000020: 'RootChanged',
    0x00000040: 'Mount', 0x00000080: 'Unmount', 0x00000100: 'ItemCreated',
    0x00000200: 'ItemRemoved', 0x00000400: 'ItemInodeMetaMod', 0x00000800: 'ItemRenamed',
    0x00001000: 'ItemModified', 0x00002000: 'ItemFinderInfoMod', 0x00004000: 'ItemChangeOwner',
    0x00008000: 'ItemXattrMod', 0x00010000: 'ItemIsFile', 0x00020000: 'ItemIsDir',
    0x00040000: 'ItemIsSymlink', 0x00080000: 'OwnEvent', 0x00100000: 'ItemIsHardlink',
    0x00200000: 'ItemIsLastHardlink', 0x00400000: 'ItemCloned',
}
darwin_known_flag_mask = sum(darwin_event_flag_names)
darwin_integrity_names = {'MustScanSubDirs', 'UserDropped', 'KernelDropped', 'EventIdsWrapped', 'RootChanged', 'Mount', 'Unmount'}
path_material_flags = {'Created', 'Removed', 'Renamed', 'MovedFrom', 'MovedTo', 'Updated', 'Link', 'CloseWrite', 'ItemCloned', 'OwnerModified', 'AttributeModified', 'FSEventsUnspecified'}

def record_key(record):
    key = (record.get('callbackBatchSequence'), record.get('callbackRecordSequence'))
    if any(type(part) is not int or part < 1 for part in key):
        raise SystemExit('source-tree guard ledger record key is invalid')
    return key

def decode_raw_flags(raw_flags):
    if type(raw_flags) is not int or raw_flags < 0 or raw_flags & ~darwin_known_flag_mask:
        raise SystemExit('source-tree guard paired raw flags are invalid')
    native_names = {name for flag, name in darwin_event_flag_names.items() if raw_flags & flag}
    if native_names.intersection(darwin_integrity_names):
        raise SystemExit('source-tree guard paired raw flags are invalid')
    normalized = set()
    mappings = (
        ('ItemCreated', 'Created'), ('ItemRemoved', 'Removed'), ('ItemRenamed', 'Renamed'),
        ('ItemModified', 'Updated'), ('ItemChangeOwner', 'OwnerModified'), ('ItemCloned', 'ItemCloned'),
        ('ItemIsFile', 'IsFile'), ('ItemIsDir', 'IsDir'), ('ItemIsSymlink', 'IsSymLink'),
    )
    for native_name, normalized_name in mappings:
        if native_name in native_names:
            normalized.add(normalized_name)
    if native_names.intersection({'ItemInodeMetaMod', 'ItemFinderInfoMod', 'ItemXattrMod'}):
        normalized.add('AttributeModified')
    if native_names.intersection({'ItemIsHardlink', 'ItemIsLastHardlink'}):
        normalized.add('Link')
    if not normalized:
        normalized.add('FSEventsUnspecified')
    return sorted(normalized)

with open(events_path, encoding='utf-8') as stream:
    for line_number, line in enumerate(stream, 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f'source-tree guard ledger line {line_number} is invalid: {error}') from error
        record_type = record.get('recordType') if isinstance(record, dict) else None
        if record_type not in counts:
            raise SystemExit(f'source-tree guard ledger record type is invalid: {record_type!r}')
        counts[record_type] += 1
        key = record_key(record)
        target = raw_by_key if record_type == 'raw-darwin-fsevents' else classified_by_key
        if key in target:
            raise SystemExit(f'duplicate source-tree guard {record_type} record key')
        target[key] = record
        if record_type == 'classified-darwin-fsevents':
            if any(type(record.get(field)) is not bool for field in ('included', 'material', 'violates')):
                raise SystemExit('source-tree guard classified boolean field is invalid')
            if record['violates'] != (record['included'] and record['material']):
                raise SystemExit('source-tree guard classified boolean invariant failed')
            violating_record_count += int(record['violates'])
            reconciliation = record.get('cloneReconciliation')
            if reconciliation is not None and (
                not isinstance(reconciliation, dict)
                or reconciliation.get('status') not in allowed_reconciliation_statuses
                or reconciliation.get('policy') != POLICY
            ):
                raise SystemExit('source-tree guard reconciliation status is invalid')
            if isinstance(reconciliation, dict) and reconciliation.get('status') == 'clone-observed-no-delta':
                no_delta_records.append(record)
if not set(classified_by_key).issubset(raw_by_key):
    raise SystemExit('source-tree guard classified record has no raw pair')
for key, record in classified_by_key.items():
    raw = raw_by_key[key]
    normalized_flags = decode_raw_flags(raw.get('rawFlags'))
    if (
        type(raw.get('eventId')) is not int or raw['eventId'] < 0
        or raw.get('eventId') != record.get('eventId')
        or not isinstance(raw.get('path'), str) or not raw['path']
        or raw.get('path') != record.get('path')
        or record.get('flags') != normalized_flags
    ):
        raise SystemExit('source-tree guard paired record identity/flags mismatch')
    if record.get('cloneReconciliation') is None and record['material'] != bool(set(normalized_flags).intersection(path_material_flags)):
        raise SystemExit('source-tree guard classified material does not match raw flags')
for record in classified_by_key.values():
    reconciliation = record.get('cloneReconciliation')
    if reconciliation is None:
        continue
    raw = raw_by_key[record_key(record)]
    status = reconciliation.get('status')
    baseline_fingerprint = reconciliation.get('baseline')
    current_fingerprint = reconciliation.get('current')
    if (
        raw.get('rawFlags') != 0x00410000 or raw.get('eventId') != record.get('eventId')
        or raw.get('path') != record.get('path') or record.get('flags') != ['IsFile', 'ItemCloned']
        or record.get('included') is not True or reconciliation.get('policy') != POLICY
    ):
        raise SystemExit('source-tree guard clone reconciliation proof failed')
    if status == 'clone-baseline-missing':
        valid_semantics = (
            record.get('material') is True and record.get('violates') is True
            and set(reconciliation) == {'policy', 'status'}
        )
    else:
        sidecar_record = records_by_path.get(record.get('path'))
        binding_matches = (
            set(reconciliation) == {
                'policy', 'status', 'baselineCanonicalPath',
                'baselineEventScope', 'baselineManifestEntries',
                'baseline', 'current',
            }
            and sidecar_record is not None
            and record.get('scope') == sidecar_record['eventScope']
            and reconciliation.get('baselineCanonicalPath') == sidecar_record['canonicalPath']
            and reconciliation.get('baselineEventScope') == sidecar_record['eventScope']
            and reconciliation.get('baselineManifestEntries') == sidecar_record['manifestEntries']
            and baseline_fingerprint == sidecar_record['fingerprint']
        )
        if status == 'clone-observed-delta':
            valid_semantics = (
                binding_matches and record.get('material') is True and record.get('violates') is True
                and valid_fingerprint(current_fingerprint) and current_fingerprint != baseline_fingerprint
            )
        else:
            valid_semantics = (
                binding_matches and record.get('material') is False and record.get('violates') is False
                and valid_fingerprint(current_fingerprint) and current_fingerprint == baseline_fingerprint
            )
    if not valid_semantics:
        raise SystemExit('source-tree guard clone reconciliation proof failed')
raw_count = value.get('rawCallbackRecordCount')
classified_count = value.get('classifiedEventCount')
fatal_count = value.get('fatalRawRecordCount')
suppressed_count = value.get('suppressedInternalSinkEventCount')
clone_no_delta_count = value.get('cloneObservedNoDeltaEventCount')
reported_violating_count = value.get('violatingEventCount')
observed_count = value.get('observedEventCount')
bootstrap_count = value.get('bootstrapEventCount')
ready_bootstrap_count = ready_value.get('bootstrapEventCount')
if (
    any(type(item) is not int or item < 0 for item in (raw_count, classified_count, fatal_count, suppressed_count, clone_no_delta_count, reported_violating_count, observed_count, bootstrap_count, ready_bootstrap_count))
    or bootstrap_count != ready_bootstrap_count
    or observed_count != classified_count - bootstrap_count
    or raw_count != counts['raw-darwin-fsevents']
    or classified_count != counts['classified-darwin-fsevents']
    or fatal_count != len(set(raw_by_key) - set(classified_by_key))
    or clone_no_delta_count != len(no_delta_records)
    or reported_violating_count != violating_record_count
):
    raise SystemExit('source-tree guard ledger count mismatch')

if (
    value.get('version') != 3 or ready_value.get('version') != 3
    or value.get('nonce') != nonce or ready_value.get('nonce') != nonce
    or value.get('watcherBackend') != 'darwin-fsevents'
    or value.get('status') != 'stopped' or value.get('readyWritten') is not True
    or type(value.get('startedEpochUs')) is not int or value['startedEpochUs'] < launched
    or type(value.get('stopRequestedEpochUs')) is not int
    or value['stopRequestedEpochUs'] < stop_before
    or type(value.get('endedEpochUs')) is not int
    or value['stopRequestedEpochUs'] > value['endedEpochUs']
    or stop_after < stop_before
    or value.get('canaryCreatedObserved') is not True or value.get('canaryRemovedObserved') is not True
    or reported_violating_count != 0
    or value.get('cloneReconciliationPolicy') != POLICY
    or ready_value.get('cloneReconciliationPolicy') != POLICY
    or fatal_count != 0 or raw_count != classified_count
    or value.get('guardError') is not None
    or not isinstance(termination, dict)
    or termination.get('contained') is not True or termination.get('exitCode') != 0
    or termination.get('flushSyncRequested') is not True or termination.get('flushSyncCompleted') is not True
    or termination.get('drainedSentinelEmitted') is not True or termination.get('drainedSentinelObserved') is not True
):
    raise SystemExit('source-tree guard result did not prove an unchanged tree')
print(f"status={value['status']}")
print(f"observed_events={value['observedEventCount']}")
print(f"baseline_unique_files={attestation['baselineUniqueRegularFileCount']}")
print('unchanged_tree_verified=true')
PY
assert_android_sdk_sandbox_binding
shasum -a 256 "$ISOLATED_GRADLE_PROPERTIES" \
  > "$EVIDENCE/isolated-gradle-properties.post.sha256"
cmp "$EVIDENCE/isolated-gradle-properties.pre.sha256" \
  "$EVIDENCE/isolated-gradle-properties.post.sha256" \
  || die "isolated Gradle properties pre/post hashes differ"
cleanup_rig || die "final rig cleanup, field isolation, or settings restoration failed"
cleanup_isolated_gradle_home \
  || die "isolated Gradle home could not be removed safely"
cleanup_isolated_user_home \
  || die "isolated Flutter/Android user home could not be removed safely"

summary_sha=$(shasum -a 256 "$EVIDENCE/summary.json" | awk '{print $1}')
tested_tree_sha=$(shasum -a 256 "$EVIDENCE/tested-files.post.sha256" | awk '{print $1}')
source_guard_sha=$(shasum -a 256 "$SOURCE_GUARD_RESULT" | awk '{print $1}')
bootstrap_source_guard_sha=$(shasum -a 256 \
  "$BOOTSTRAP_SOURCE_GUARD_RESULT" | awk '{print $1}')
android_toolchain_manifest_sha=$(shasum -a 256 \
  "$EVIDENCE/android-toolchain.post.sha256" | awk '{print $1}')
android_toolchain_roots_sha=$(shasum -a 256 \
  "$EVIDENCE/android-toolchain.roots.post.json" | awk '{print $1}')
android_toolchain_discovery_sha=$(shasum -a 256 \
  "$EVIDENCE/android-toolchain.discovery.json" | awk '{print $1}')
native_cache_cleanup_pre_sha=$(shasum -a 256 \
  "$EVIDENCE/external-native-cache-cleanup.pre.json" | awk '{print $1}')
native_cache_cleanup_post_sha=$(shasum -a 256 \
  "$EVIDENCE/external-native-cache-cleanup.post.json" | awk '{print $1}')
flutter_gradle_cleanup_pre_sha=$(shasum -a 256 \
  "$EVIDENCE/flutter-gradle-generated-cleanup.pre.json" | awk '{print $1}')
flutter_gradle_cleanup_post_sha=$(shasum -a 256 \
  "$EVIDENCE/flutter-gradle-generated-cleanup.post.json" | awk '{print $1}')
generated_input_cleanup_sha=$(shasum -a 256 \
  "$EVIDENCE/generated-input-cleanup.json" | awk '{print $1}')
native_cache_freshness_sha=$(shasum -a 256 \
  "$EVIDENCE/native-cache-freshness-validated.json" | awk '{print $1}')
android_sdk_sandbox_prepare_sha=$ANDROID_SDK_SANDBOX_PREPARED_SHA256
android_sdk_sandbox_post_sha=$(shasum -a 256 \
  "$ANDROID_SDK_SANDBOX_POST_EVIDENCE" | awk '{print $1}')
[[ -n "$FINAL_PROCESS_SCOPE_EVIDENCE" \
  && -f "$FINAL_PROCESS_SCOPE_EVIDENCE" \
  && ! -L "$FINAL_PROCESS_SCOPE_EVIDENCE" ]] \
  || die "final process-scope cleanup evidence is unavailable"
process_scope_cleanup_sha=$(shasum -a 256 \
  "$FINAL_PROCESS_SCOPE_EVIDENCE" | awk '{print $1}')
"$PYTHON" -I -S -B - "$EVIDENCE/runner-result.json" "$summary_sha" "$tested_tree_sha" \
  "$source_guard_sha" "$android_toolchain_manifest_sha" \
  "$android_toolchain_roots_sha" "$PYTHON_SHA256" \
  "$bootstrap_source_guard_sha" "$android_toolchain_discovery_sha" \
  "$native_cache_cleanup_pre_sha" "$native_cache_cleanup_post_sha" \
  "$flutter_gradle_cleanup_pre_sha" "$flutter_gradle_cleanup_post_sha" \
  "$generated_input_cleanup_sha" "$native_cache_freshness_sha" \
  "$android_sdk_sandbox_prepare_sha" "$android_sdk_sandbox_post_sha" \
  "$ANDROID_SDK_SANDBOX_PROFILE_SHA256" \
  "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256" \
  "$ANDROID_SDK_SANDBOX_PROBE_SHA256" \
  "$ANDROID_SDK_SANDBOX_PREFLIGHT_SHA256" \
  "$ANDROID_SDK_SANDBOX_EXEC_SHA256" \
  "$PROCESS_SCOPE_HELPER_SHA256" \
  "$SCOPED_COMMAND_SHA256" \
  "$process_scope_cleanup_sha" \
  "${GATE_CUTS[@]}" <<'PY'
import json, pathlib, sys
(
    output,
    summary_sha,
    tree_sha,
    guard_sha,
    android_toolchain_manifest_sha,
    android_toolchain_roots_sha,
    python_executable_sha,
    bootstrap_guard_sha,
    android_toolchain_discovery_sha,
    native_cache_cleanup_pre_sha,
    native_cache_cleanup_post_sha,
    flutter_gradle_cleanup_pre_sha,
    flutter_gradle_cleanup_post_sha,
    generated_input_cleanup_sha,
    native_cache_freshness_sha,
    android_sdk_sandbox_prepare_sha,
    android_sdk_sandbox_post_sha,
    android_sdk_sandbox_profile_sha,
    android_sdk_sandbox_wrapper_sha,
    android_sdk_sandbox_probe_sha,
    android_sdk_sandbox_preflight_sha,
    android_sdk_sandbox_exec_sha,
    process_scope_helper_sha,
    scoped_command_helper_sha,
    process_scope_cleanup_sha,
    *cuts,
) = sys.argv[1:]
expected = [
    'allocated', 'sourceVerified', 'handedOffBeforePlatform',
    'platformInvoked', 'pendingResult', 'neverResult', 'realPluginMirror',
]
if cuts != expected:
    raise SystemExit('unexpected final Gate C cut set/order')
value = {
    'version': 1,
    'result': 'pass',
    'summarySha256': summary_sha,
    'testedTreeManifestSha256': tree_sha,
    'sourceTreeGuardResultSha256': guard_sha,
    'bootstrapSourceTreeGuardResultSha256': bootstrap_guard_sha,
    'androidToolchainManifestSha256': android_toolchain_manifest_sha,
    'androidToolchainRootsSha256': android_toolchain_roots_sha,
    'androidToolchainDiscoverySha256': android_toolchain_discovery_sha,
    'externalNativeCacheCleanupPreSha256': native_cache_cleanup_pre_sha,
    'externalNativeCacheCleanupPostSha256': native_cache_cleanup_post_sha,
    'flutterGradleGeneratedCleanupPreSha256': flutter_gradle_cleanup_pre_sha,
    'flutterGradleGeneratedCleanupPostSha256': flutter_gradle_cleanup_post_sha,
    'generatedInputCleanupSha256': generated_input_cleanup_sha,
    'nativeCacheFreshnessValidationSha256': native_cache_freshness_sha,
    'androidSdkSandboxPrepareSha256': android_sdk_sandbox_prepare_sha,
    'androidSdkSandboxPostSha256': android_sdk_sandbox_post_sha,
    'androidSdkSandboxProfileSha256': android_sdk_sandbox_profile_sha,
    'androidSdkSandboxWrapperSha256': android_sdk_sandbox_wrapper_sha,
    'androidSdkSandboxProbeSha256': android_sdk_sandbox_probe_sha,
    'androidSdkSandboxPreflightSha256': android_sdk_sandbox_preflight_sha,
    'androidSdkSandboxExecSha256': android_sdk_sandbox_exec_sha,
    'processScopeHelperSha256': process_scope_helper_sha,
    'scopedCommandHelperSha256': scoped_command_helper_sha,
    'processScopeCleanupSha256': process_scope_cleanup_sha,
    'pythonExecutableSha256': python_executable_sha,
    'cuts': cuts,
    'cleanupVerified': True,
}
pathlib.Path(output).write_text(
    json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n',
    encoding='utf-8',
)
PY
(
  cd "$EVIDENCE"
  find . -type f \
    ! -name RUN_SHA256SUMS \
    ! -name runner.log \
    ! -name runner-exit.txt \
    ! -name wrapper-identity.txt \
    ! -name wrapper-before-state.txt \
    ! -name wrapper-after-state.txt \
    -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 > RUN_SHA256SUMS
  shasum -a 256 -c RUN_SHA256SUMS > /dev/null
)
print -r -- "telemetry memory rig: PASS ($EVIDENCE)"
