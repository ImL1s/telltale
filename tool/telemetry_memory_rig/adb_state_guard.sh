#!/bin/zsh -f

# Source-only, fail-closed ADB state helpers for the telemetry Gate C runner.
# The caller must bind ADB, SERIAL, PACKAGE, and FIELD_PACKAGE.

_gate_c_adb_bound() {
  [[ -n ${ADB:-} && -n ${SERIAL:-} && -n ${PACKAGE:-} && -n ${FIELD_PACKAGE:-} ]]
}

_gate_c_adb_clean_output() {
  local value=$1
  value=${value//$'\r\n'/$'\n'}
  value=${value%$'\r'}
  [[ "$value" != *$'\r'* && "$value" != *$'\0'* ]] || return 1
  print -rn -- "$value"
}

gate_c_adb_require_online() {
  _gate_c_adb_bound || return 1
  local output
  if ! output=$("$ADB" -s "$SERIAL" get-state); then
    return 1
  fi
  output=$(_gate_c_adb_clean_output "$output") || return 1
  [[ "$output" == device ]]
}

# Run an Android shell command only after a fresh online proof. Stdout and the
# exact adb/remote return code are passed through to the caller.
gate_c_adb_shell_capture() {
  (( $# > 0 )) || return 1
  gate_c_adb_require_online || return 1
  "$ADB" -s "$SERIAL" shell "$@"
}

# Print a canonical space-separated PID list. A remote pidof status of 1 is
# accepted only with blank output and only after the fresh online proof above.
gate_c_adb_optional_pidof() {
  local package=${1:-} output adb_rc remote_rc sentinel body command
  [[ -n "$package" && "$package" != *[^A-Za-z0-9._]* ]] || return 1
  gate_c_adb_require_online || return 1
  command="pidof $package; remote_rc=\$?; printf '\\n__TELLTALE_PIDOF_RC__=%s\\n' \"\$remote_rc\""
  if output=$("$ADB" -s "$SERIAL" shell "$command"); then
    adb_rc=0
  else
    adb_rc=$?
  fi
  (( adb_rc == 0 )) || return "$adb_rc"
  output=$(_gate_c_adb_clean_output "$output") || return 1
  [[ "$output" == *$'\n'__TELLTALE_PIDOF_RC__=<-> ]] || return 1
  sentinel=${output##*$'\n'}
  [[ "$sentinel" == __TELLTALE_PIDOF_RC__=<-> ]] || return 1
  remote_rc=${sentinel#__TELLTALE_PIDOF_RC__=}
  body=${output%$'\n'$sentinel}
  while [[ "$body" == *$'\n' ]]; do
    body=${body%$'\n'}
  done
  if (( remote_rc == 1 )); then
    [[ -z "$body" ]] || return 1
    return 0
  fi
  (( remote_rc == 0 )) || return "$remote_rc"
  [[ -n "$body" && "$body" != *$'\n'* ]] || return 1
  local -a pids
  pids=(${=body})
  [[ "${(j: :)pids}" == "$body" ]] || return 1
  local pid
  for pid in $pids; do
    [[ "$pid" == <-> && "$pid" != 0 ]] || return 1
  done
  print -r -- "${(j: :)pids}"
}

gate_c_adb_required_single_pid() {
  local package=${1:-} pid
  pid=$(gate_c_adb_optional_pidof "$package") || return 1
  [[ "$pid" == <-> && "$pid" != 0 ]] || return 1
  print -r -- "$pid"
}

# Capture one attributable TOTAL PSS sample with one fresh online proof and one
# remote shell transaction. The printed fields are start_us, end_us, pid, and
# total_pss_kb. A canonically absent process returns success with blank output.
gate_c_adb_total_pss_sample() {
  local package=${1:-} expected_pid=${2:-}
  local command output adb_rc
  local start_rc start_ns pid_rc pid meminfo_rc pss_count pss_kb end_rc end_ns
  [[ -n "$package" && "$package" != *[^A-Za-z0-9._]* ]] || return 1
  [[ -z "$expected_pid" || ( "$expected_pid" == <-> && "$expected_pid" != 0 ) ]] \
    || return 1
  gate_c_adb_require_online || return 1
  command="start_output=\$(date +%s%N 2>&1); start_rc=\$?; pid_output=\$(pidof $package 2>&1); pid_rc=\$?; meminfo_rc=125; pss_count=0; pss_kb=;
if [ \"\$pid_rc\" -eq 0 ]; then
  case \"\$pid_output\" in
    ''|*[!0-9]*) ;;
    *)
      meminfo_output=\$(dumpsys meminfo \"\$pid_output\" 2>&1); meminfo_rc=\$?;
      if [ \"\$meminfo_rc\" -eq 0 ]; then
        summary_values=\$(printf '%s\\n' \"\$meminfo_output\" | sed -n \
          -e 's/^[[:space:]]*TOTAL PSS:[[:space:]]*\\([0-9][0-9]*\\)[[:space:]].*\$/\\1/p' \
          -e 's/^[[:space:]]*TOTAL PSS:[[:space:]]*\\([0-9][0-9]*\\)\$/\\1/p'); summary_rc=\$?;
        table_values=\$(printf '%s\\n' \"\$meminfo_output\" | sed -n \
          -e 's/^[[:space:]]*TOTAL[[:space:]][[:space:]]*\\([0-9][0-9]*\\)[[:space:]].*\$/\\1/p' \
          -e 's/^[[:space:]]*TOTAL[[:space:]][[:space:]]*\\([0-9][0-9]*\\)\$/\\1/p'); table_rc=\$?;
        if [ \"\$summary_rc\" -eq 0 ] && [ \"\$table_rc\" -eq 0 ]; then
          summary_count=0; summary_kb=;
          case \"\$summary_values\" in '') ;; *[!0-9]*) summary_count=2 ;; *) summary_count=1; summary_kb=\$summary_values ;; esac;
          table_count=0; table_kb=;
          case \"\$table_values\" in '') ;; *[!0-9]*) table_count=2 ;; *) table_count=1; table_kb=\$table_values ;; esac;
          if [ \"\$summary_count\" -eq 1 ] && [ \"\$table_count\" -eq 0 ]; then
            pss_count=1; pss_kb=\$summary_kb;
          elif [ \"\$summary_count\" -eq 0 ] && [ \"\$table_count\" -eq 1 ]; then
            pss_count=1; pss_kb=\$table_kb;
          elif [ \"\$summary_count\" -eq 1 ] && [ \"\$table_count\" -eq 1 ] && [ \"\$summary_kb\" = \"\$table_kb\" ]; then
            pss_count=1; pss_kb=\$summary_kb;
          else
            pss_count=2; pss_kb=;
          fi;
        else
          meminfo_rc=126;
        fi;
      fi ;;
  esac;
fi;
end_output=\$(date +%s%N 2>&1); end_rc=\$?;
printf '%s\\n' '__TELLTALE_PSS_SAMPLE_V1_BEGIN__' \"start_rc=\$start_rc\" \"start_ns=\$start_output\" \"pid_rc=\$pid_rc\" \"pid=\$pid_output\" \"meminfo_rc=\$meminfo_rc\" \"pss_count=\$pss_count\" \"pss_kb=\$pss_kb\" \"end_rc=\$end_rc\" \"end_ns=\$end_output\" '__TELLTALE_PSS_SAMPLE_V1_END__'"
  if output=$("$ADB" -s "$SERIAL" shell "$command"); then
    adb_rc=0
  else
    adb_rc=$?
  fi
  (( adb_rc == 0 )) || return "$adb_rc"
  output=$(_gate_c_adb_clean_output "$output") || return 1
  local -a lines
  lines=("${(@f)output}")
  (( ${#lines} == 11 )) || return 1
  [[ "${lines[1]}" == __TELLTALE_PSS_SAMPLE_V1_BEGIN__ \
    && "${lines[11]}" == __TELLTALE_PSS_SAMPLE_V1_END__ ]] || return 1
  [[ "${lines[2]}" == start_rc=<-> \
    && "${lines[3]}" == start_ns=* \
    && "${lines[4]}" == pid_rc=<-> \
    && "${lines[5]}" == pid=* \
    && "${lines[6]}" == meminfo_rc=<-> \
    && "${lines[7]}" == pss_count=<-> \
    && "${lines[8]}" == pss_kb=* \
    && "${lines[9]}" == end_rc=<-> \
    && "${lines[10]}" == end_ns=* ]] || return 1
  start_rc=${lines[2]#start_rc=}
  start_ns=${lines[3]#start_ns=}
  pid_rc=${lines[4]#pid_rc=}
  pid=${lines[5]#pid=}
  meminfo_rc=${lines[6]#meminfo_rc=}
  pss_count=${lines[7]#pss_count=}
  pss_kb=${lines[8]#pss_kb=}
  end_rc=${lines[9]#end_rc=}
  end_ns=${lines[10]#end_ns=}
  (( start_rc == 0 && end_rc == 0 )) || return 1
  [[ "$start_ns" == <-> && "$start_ns" != 0 \
    && "$end_ns" == <-> && "$end_ns" != 0 ]] || return 1
  (( end_ns >= start_ns && end_ns - start_ns <= 1000000000 )) || return 1
  if (( pid_rc == 1 )); then
    [[ -z "$pid" && "$meminfo_rc" == 125 && "$pss_count" == 0 \
      && -z "$pss_kb" ]] || return 1
    [[ -z "$expected_pid" ]] || return 1
    return 0
  fi
  (( pid_rc == 0 && meminfo_rc == 0 && pss_count == 1 )) || return 1
  [[ "$pid" == <-> && "$pid" != 0 \
    && "$pss_kb" == <-> && "$pss_kb" != 0 ]] || return 1
  [[ -z "$expected_pid" || "$pid" == "$expected_pid" ]] || return 1
  print -r -- "$(( start_ns / 1000 ))"$'\t'"$(( end_ns / 1000 ))"$'\t'"$pid"$'\t'"$pss_kb"
}

_gate_c_adb_pm_path() {
  local allow_absent=$1 package=$2 output adb_rc remote_rc sentinel body command line
  [[ "$allow_absent" == 0 || "$allow_absent" == 1 ]] || return 1
  [[ -n "$package" && "$package" != *[^A-Za-z0-9._]* ]] || return 1
  gate_c_adb_require_online || return 1
  command="pm path $package 2>&1; remote_rc=\$?; printf '\n__TELLTALE_PM_PATH_RC__=%s\n' \"\$remote_rc\""
  if output=$("$ADB" -s "$SERIAL" shell "$command"); then
    adb_rc=0
  else
    adb_rc=$?
  fi
  (( adb_rc == 0 )) || return "$adb_rc"
  output=$(_gate_c_adb_clean_output "$output") || return 1
  [[ "$output" == *$'\n'__TELLTALE_PM_PATH_RC__=<-> ]] || return 1
  sentinel=${output##*$'\n'}
  [[ "$sentinel" == __TELLTALE_PM_PATH_RC__=<-> ]] || return 1
  remote_rc=${sentinel#__TELLTALE_PM_PATH_RC__=}
  body=${output%$'\n'$sentinel}
  while [[ "$body" == *$'\n' ]]; do
    body=${body%$'\n'}
  done
  if (( remote_rc == 1 )); then
    [[ "$allow_absent" == 1 && -z "$body" ]] || return 1
    return 0
  fi
  (( remote_rc == 0 )) || return "$remote_rc"
  [[ -n "$body" ]] || return 1
  local -a lines canonical
  lines=("${(@f)body}")
  for line in $lines; do
    [[ "$line" == package:/* && "$line" != *[$'\t\n\r ']* ]] || return 1
    canonical+=("$line")
  done
  (( ${#canonical} > 0 )) || return 1
  canonical=("${(@on)canonical}")
  print -r -- "${(j:;:)canonical}"
}

gate_c_adb_pm_path_capture() {
  local package=${1:-}
  [[ -n "$package" && "$package" != *$'\n'* && "$package" != *$'\r'* ]] || return 1
  _gate_c_adb_pm_path 0 "$package"
}

gate_c_adb_optional_pm_path() {
  local package=${1:-}
  [[ -n "$package" && "$package" != *$'\n'* && "$package" != *$'\r'* ]] || return 1
  _gate_c_adb_pm_path 1 "$package"
}

_gate_c_adb_setting() {
  local namespace=$1 key=$2 kind=$3 output
  if ! output=$(gate_c_adb_shell_capture settings get "$namespace" "$key"); then
    return 1
  fi
  output=$(_gate_c_adb_clean_output "$output") || return 1
  [[ -n "$output" && "$output" != *$'\n'* && "$output" != *$'\t'* && "$output" != *' '* ]] \
    || return 1
  case "$kind" in
    scale)
      [[ "$output" == <->(|.<->) || "$output" == .<-> ]] || return 1
      ;;
    rotation-enabled)
      [[ "$output" == 0 || "$output" == 1 ]] || return 1
      ;;
    rotation)
      [[ "$output" == [0-3] ]] || return 1
      ;;
    *) return 1 ;;
  esac
  print -r -- "$output"
}

gate_c_adb_settings_capture() {
  local font_scale accelerometer_rotation user_rotation
  font_scale=$(_gate_c_adb_setting system font_scale scale) || return 1
  accelerometer_rotation=$(_gate_c_adb_setting system accelerometer_rotation rotation-enabled) \
    || return 1
  user_rotation=$(_gate_c_adb_setting system user_rotation rotation) || return 1
  print -r -- "font_scale=$font_scale"
  print -r -- "accelerometer_rotation=$accelerometer_rotation"
  print -r -- "user_rotation=$user_rotation"
}

_gate_c_adb_safe_evidence_target() {
  local target=$1 parent current part
  [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] || return 1
  [[ ! -e "$target" && ! -L "$target" ]] || return 1
  parent=${target:h}
  [[ -d "$parent" && ! -L "$parent" && -O "$parent" ]] || return 1
  current=/
  local -a parts
  parts=(${(s:/:)${parent#/}})
  for part in $parts; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    current=${current%/}/$part
    [[ -d "$current" && ! -L "$current" ]] || return 1
  done
}

_gate_c_adb_atomic_lines() {
  local target=$1
  shift
  _gate_c_adb_safe_evidence_target "$target" || return 1
  local temporary
  temporary=$(mktemp "${target}.tmp.XXXXXX") || return 1
  chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  if ! printf '%s\n' "$@" >| "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

_gate_c_adb_package_state() {
  local label=$1 package=$2 path pid
  path=$(gate_c_adb_optional_pm_path "$package") || return 1
  pid=$(gate_c_adb_optional_pidof "$package") || return 1
  print -r -- "${label}_path=${path:-absent}"
  print -r -- "${label}_pid=${pid:-absent}"
}

gate_c_adb_snapshot() {
  local target=${1:-} rig_state field_state settings
  [[ -n "$target" ]] || return 1
  gate_c_adb_require_online || return 1
  rig_state=$(_gate_c_adb_package_state rig "$PACKAGE") || return 1
  field_state=$(_gate_c_adb_package_state field "$FIELD_PACKAGE") || return 1
  settings=$(gate_c_adb_settings_capture) || return 1
  _gate_c_adb_atomic_lines "$target" \
    "serial=$SERIAL" "device_state=device" \
    "${(@f)rig_state}" "${(@f)field_state}" "${(@f)settings}"
}

gate_c_adb_remove_rig_package() {
  local target=${1:-} before_path before_pid force_output uninstall_output
  local after_force_pid after_path after_pid
  [[ -n "$target" ]] || return 1
  gate_c_adb_require_online || return 1
  before_path=$(gate_c_adb_optional_pm_path "$PACKAGE") || return 1
  before_pid=$(gate_c_adb_optional_pidof "$PACKAGE") || return 1
  [[ -n "$before_path" || -z "$before_pid" ]] || return 1

  local force_status=not-needed uninstall_status=not-needed
  if [[ -n "$before_pid" ]]; then
    if ! force_output=$(gate_c_adb_shell_capture am force-stop "$PACKAGE"); then
      return 1
    fi
    force_output=$(_gate_c_adb_clean_output "$force_output") || return 1
    [[ -z "$force_output" ]] || return 1
    after_force_pid=$(gate_c_adb_optional_pidof "$PACKAGE") || return 1
    [[ -z "$after_force_pid" ]] || return 1
    force_status=success
  fi
  if [[ -n "$before_path" ]]; then
    gate_c_adb_require_online || return 1
    if ! uninstall_output=$("$ADB" -s "$SERIAL" uninstall "$PACKAGE"); then
      return 1
    fi
    uninstall_output=$(_gate_c_adb_clean_output "$uninstall_output") || return 1
    [[ "$uninstall_output" == Success ]] || return 1
    uninstall_status=success
  fi

  gate_c_adb_require_online || return 1
  after_path=$(gate_c_adb_optional_pm_path "$PACKAGE") || return 1
  [[ -z "$after_path" ]] || return 1
  after_pid=$(gate_c_adb_optional_pidof "$PACKAGE") || return 1
  [[ -z "$after_pid" ]] || return 1
  _gate_c_adb_atomic_lines "$target" \
    "serial=$SERIAL" "device_state=device" \
    "rig_path_before=${before_path:-absent}" \
    "rig_pid_before=${before_pid:-absent}" \
    "force_stop=$force_status" "uninstall=$uninstall_status" \
    "rig_path_after=absent" "rig_pid_after=absent"
}
