#!/bin/zsh -f
set -euo pipefail
umask 077

die() { print -u2 -- "sealed Gradle Flutter: $*"; exit 64; }

[[ ${ORG_GRADLE_PROJECT_telltaleGateCRigDebug:-} == true ]] \
  || die "telltaleGateCRigDebug must be exactly true"
[[ -n ${TELLTALE_GATE_C_FLUTTER_ROOT:-} ]] \
  || die "TELLTALE_GATE_C_FLUTTER_ROOT is not bound"
[[ -n ${TELLTALE_GATE_C_JDK_ROOT:-} ]] \
  || die "TELLTALE_GATE_C_JDK_ROOT is not bound"
[[ -n ${JAVA_HOME:-} ]] \
  || die "JAVA_HOME is not bound"

HERE=${0:A:h}
SEALED_SDK_EXEC="$HERE/sealed_sdk_exec.sh"
FLUTTER_ROOT=${TELLTALE_GATE_C_FLUTTER_ROOT:A}
JDK_ROOT=${TELLTALE_GATE_C_JDK_ROOT:A}
JAVA_HOME_ROOT=${JAVA_HOME:A}

[[ -x "$SEALED_SDK_EXEC" && -f "$SEALED_SDK_EXEC" && ! -L "$SEALED_SDK_EXEC" ]] \
  || die "sealed SDK executor is missing or unsafe"
[[ -d "$FLUTTER_ROOT" && ! -L "$FLUTTER_ROOT" ]] \
  || die "bound Flutter root is missing or unsafe"
[[ -d "$JDK_ROOT" && ! -L "$JDK_ROOT" \
  && -x "$JDK_ROOT/bin/java" && ! -L "$JDK_ROOT/bin/java" ]] \
  || die "bound Gate C JDK root is missing or unsafe"
[[ "$JAVA_HOME_ROOT" == "$JDK_ROOT" ]] \
  || die "JAVA_HOME does not match TELLTALE_GATE_C_JDK_ROOT"

exec "$SEALED_SDK_EXEC" "$FLUTTER_ROOT" flutter "$@"
