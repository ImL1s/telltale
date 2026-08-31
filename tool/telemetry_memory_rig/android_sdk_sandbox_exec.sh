#!/bin/zsh -f
set -euo pipefail

die() { print -u2 -- "Android SDK sandbox: $*"; exit 64; }

# zsh imports the supplied environment as exported parameters, but also adds
# these shell-owned exports while starting. Remove them before the cooperative
# launch-barrier report so the parent can require the exact fixed environment
# it supplied. PWD is supplied explicitly by the parent and remains bound to
# the canonical command cwd.
unset LOGNAME OLDPWD SHLVL

required=(
  TELLTALE_GATE_C_SANDBOX_PROFILE
  TELLTALE_GATE_C_SANDBOX_APP_ROOT
  TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT
  TELLTALE_GATE_C_SANDBOX_PUB_CACHE
  TELLTALE_GATE_C_SANDBOX_GRADLE_HOME
  TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT
  TELLTALE_GATE_C_SANDBOX_RUN_TEMP
  TELLTALE_GATE_C_SANDBOX_ANDROID_SDK_ROOT
  TELLTALE_GATE_C_PROCESS_SCOPE
  TELLTALE_GATE_C_LAUNCH_RELEASE_FD
  TELLTALE_GATE_C_LAUNCH_READY_FD
)
for name in $required; do
  [[ -n ${(P)name:-} ]] || die "missing exported $name"
done
(( $# >= 2 )) || die "usage: android_sdk_sandbox_exec.sh -- command [args...]"
[[ $1 == -- ]] || die "command separator must be --"
shift

[[ ${#TELLTALE_GATE_C_PROCESS_SCOPE} == 32 \
  && $TELLTALE_GATE_C_PROCESS_SCOPE != *[^0-9a-f]* ]] \
  || die "launch ID is not canonical"
[[ $TELLTALE_GATE_C_LAUNCH_RELEASE_FD == <3-> \
  && $TELLTALE_GATE_C_LAUNCH_READY_FD == <3-> \
  && $TELLTALE_GATE_C_LAUNCH_RELEASE_FD \
    != $TELLTALE_GATE_C_LAUNCH_READY_FD ]] \
  || die "launch barrier descriptors are invalid"

integer release_fd=$TELLTALE_GATE_C_LAUNCH_RELEASE_FD
integer ready_fd=$TELLTALE_GATE_C_LAUNCH_READY_FD

# The parent creates this process as a fresh session leader, records its exact
# kernel identity, and only then releases it. Before release, enumerate every
# exported parameter rather than an expected subset and report only names over
# the private ready pipe. This uses zsh builtins exclusively, so no unbound
# descendant can fork before the authority and environment sidecar exist.
typeset -a exported_environment_names=()
for environment_name in ${(ko)parameters}; do
  [[ ${(tP)environment_name} == *-export* ]] || continue
  [[ $environment_name == [A-Za-z_]* \
    && $environment_name != *[^A-Za-z0-9_]* ]] \
    || die "launch environment name is not a canonical identifier"
  exported_environment_names+=($environment_name)
done
builtin print -r -u $ready_fd -- TELLTALE_GATE_C_CHILD_ENVIRONMENT_V1 \
  || die "launch barrier environment header failed"
builtin print -r -u $ready_fd -- \
  "launchId=$TELLTALE_GATE_C_PROCESS_SCOPE" \
  || die "launch barrier environment identity failed"
for environment_name in $exported_environment_names; do
  builtin print -r -u $ready_fd -- "$environment_name" \
    || die "launch barrier environment report failed"
done
builtin print -r -u $ready_fd -- . \
  || die "launch barrier environment terminator failed"
exec {ready_fd}>&-
barrier_byte=''
IFS= read -r -k 1 -u $release_fd barrier_byte \
  || die "launch barrier closed before authorization"
exec {release_fd}<&-
[[ $barrier_byte == G ]] || die "launch barrier release is invalid"

# sandbox(7) does not revoke access already represented by an open descriptor.
# After the session has been sealed, reject every descriptor that would cross
# an exec boundary. zsh itself keeps the script on a close-on-exec descriptor,
# so probe from an already-authorized child process rather than rejecting that
# harmless interpreter-internal descriptor.
integer fd
for fd_path in /dev/fd/*(N); do
  fd=${fd_path:t}
  [[ $fd == <3-> ]] || continue
  /bin/test ! -e /dev/fd/$fd || die "launch descriptor was not closed: $fd"
done

# The child-environment sidecar's actualNames is the barrier-time name set;
# values are unobserved. The schema separately declares these three names as
# post-barrier additions, so keep this export block after authorization.
# The isolated Flutter root is sealed except for the included Gradle build's
# exact generated .gradle, build, and .kotlin roots, so Flutter must still skip
# its SDK cache lock. Source files and SDK metadata remain write-denied while
# the private clone guarantees this Gate owns the invocation.
# Native tools honor TMPDIR, while the macOS JVM ignores it when selecting
# java.io.tmpdir. Bind both mechanisms to the one private, write-allowed root.
# The Kotlin daemon marker has its own runFilesPath default, so bind that too
# even though the sealed Gradle properties require in-process compilation.
export FLUTTER_ALREADY_LOCKED=true
export TMPDIR="$TELLTALE_GATE_C_SANDBOX_RUN_TEMP"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TELLTALE_GATE_C_SANDBOX_RUN_TEMP -Duser.home=$TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT/home -Dkotlin.daemon.options=runFilesPath=$TELLTALE_GATE_C_SANDBOX_RUN_TEMP/kotlin-daemon"

exec /usr/bin/sandbox-exec \
  -D "APP_ROOT=$TELLTALE_GATE_C_SANDBOX_APP_ROOT" \
  -D "FLUTTER_ROOT=$TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT" \
  -D "PUB_CACHE=$TELLTALE_GATE_C_SANDBOX_PUB_CACHE" \
  -D "GRADLE_HOME=$TELLTALE_GATE_C_SANDBOX_GRADLE_HOME" \
  -D "ISOLATED_ROOT=$TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT" \
  -D "RUN_TEMP=$TELLTALE_GATE_C_SANDBOX_RUN_TEMP" \
  -f "$TELLTALE_GATE_C_SANDBOX_PROFILE" \
  -- "$@"
