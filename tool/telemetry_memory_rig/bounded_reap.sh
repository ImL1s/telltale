#!/bin/zsh

# Source-only bounded child reaping for the telemetry memory/Gate C runner.
# The function must execute in the shell that spawned PID so `wait` can collect
# the real child exit status.

bounded_reap_now_ns() {
  local python=${PYTHON:-} command_path
  if [[ -z "$python" ]]; then
    command_path=$(command -v python3 2>/dev/null || true)
    [[ -n "$command_path" ]] || return 127
    python=${command_path:A}
  fi
  [[ -x "$python" && -f "$python" && ! -L "$python" ]] || return 127
  "$python" -I -S -B -c 'import time; print(time.monotonic_ns())'
}

bounded_reap_is_alive() {
  kill -0 "$1" 2>/dev/null
}

# Clock-independent bounded polling used only after the sealed monotonic clock
# fails.  It deliberately trades timing precision for containment: callers
# must receive a helper-failure status, but the owned child must still be
# terminated and collected.
bounded_reap_fixed_wait() {
  local pid=$1 timeout_ms=$2
  local attempts=$(( (timeout_ms + 49) / 50 ))
  (( attempts > 0 )) || attempts=1
  while (( attempts-- > 0 )); do
    bounded_reap_is_alive "$pid" || return 0
    sleep 0.05
  done
  bounded_reap_is_alive "$pid" && return 1
  return 0
}

bounded_reap_write_evidence() {
  local evidence=$1 label=$2 pid=$3 start_ns=$4 end_ns=$5 elapsed_ms=$6
  local natural_ms=$7 term_ms=$8 kill_ms=$9
  local natural_observed=${10} term_sent=${11} kill_sent=${12}
  local forced=${13} outcome=${14} exit_code=${15}
  local clock_failure=${16} clock_failure_stage=${17}
  local temp="$evidence.tmp.$$"
  mkdir -p "${evidence:h}"
  {
    print -r -- "version=1"
    print -r -- "label=$label"
    print -r -- "pid=$pid"
    print -r -- "start_monotonic_ns=$start_ns"
    print -r -- "end_monotonic_ns=$end_ns"
    print -r -- "elapsed_ms=$elapsed_ms"
    print -r -- "natural_timeout_ms=$natural_ms"
    print -r -- "term_timeout_ms=$term_ms"
    print -r -- "kill_timeout_ms=$kill_ms"
    print -r -- "natural_exit_observed=$natural_observed"
    print -r -- "term_sent=$term_sent"
    print -r -- "kill_sent=$kill_sent"
    print -r -- "forced_host_termination=$forced"
    print -r -- "outcome=$outcome"
    print -r -- "exit_code=$exit_code"
    print -r -- "clock_failure=$clock_failure"
    print -r -- "clock_failure_stage=$clock_failure_stage"
  } > "$temp"
  mv "$temp" "$evidence"
}

bounded_reap_contain_clock_failure() {
  local pid=$1 evidence=$2 label=$3
  local natural_ms=$4 term_ms=$5 kill_ms=$6 stage=$7
  local start_ns=${8:-unavailable}
  local outcome=natural_exit forced=none exit_code=127
  local natural_observed=false term_sent=false kill_sent=false

  if bounded_reap_is_alive "$pid"; then
    forced=TERM
    term_sent=true
    kill -TERM "$pid" 2>/dev/null || true
    if bounded_reap_fixed_wait "$pid" "$term_ms"; then
      outcome=terminated
    else
      forced=KILL
      kill_sent=true
      kill -KILL "$pid" 2>/dev/null || true
      if bounded_reap_fixed_wait "$pid" "$kill_ms"; then
        outcome=killed
      else
        outcome=unreaped
      fi
    fi
  fi

  if [[ "$outcome" != unreaped ]]; then
    if wait "$pid" 2>/dev/null; then exit_code=0; else exit_code=$?; fi
  fi
  bounded_reap_write_evidence \
    "$evidence" "$label" "$pid" "$start_ns" unavailable unavailable \
    "$natural_ms" "$term_ms" "$kill_ms" \
    "$natural_observed" "$term_sent" "$kill_sent" \
    "$forced" "$outcome" "$exit_code" true "$stage"
  return 127
}

bounded_reap_until() {
  local pid=$1 timeout_ms=$2
  local started_ns now_ns
  started_ns=$(bounded_reap_now_ns) || return 127
  [[ "$started_ns" == <-> ]] || return 127
  local deadline_ns=$(( started_ns + timeout_ms * 1000000 ))
  while bounded_reap_is_alive "$pid"; do
    now_ns=$(bounded_reap_now_ns) || return 127
    [[ "$now_ns" == <-> ]] || return 127
    (( now_ns >= deadline_ns )) && return 1
    sleep 0.05
  done
  return 0
}

# bounded_reap PID EVIDENCE LABEL NATURAL_MS TERM_MS KILL_MS
#
# Returns the child's exit code after a natural/forced exit, 124 if the PID
# remains alive after KILL, or 127 when the sealed monotonic clock fails.  Clock
# failure still performs TERM/KILL containment and writes fail-closed evidence.
# Callers decide whether host termination is allowed by reading
# forced_host_termination from the evidence file.
bounded_reap() {
  local pid=$1 evidence=$2 label=$3
  local natural_ms=$4 term_ms=$5 kill_ms=$6
  local start_ns
  start_ns=$(bounded_reap_now_ns) || {
    bounded_reap_contain_clock_failure \
      "$pid" "$evidence" "$label" "$natural_ms" "$term_ms" "$kill_ms" \
      start unavailable
    return $?
  }
  [[ "$start_ns" == <-> ]] || {
    bounded_reap_contain_clock_failure \
      "$pid" "$evidence" "$label" "$natural_ms" "$term_ms" "$kill_ms" \
      start_invalid unavailable
    return $?
  }
  local end_ns exit_code=124 outcome=unreaped forced=none
  local wait_status
  local natural_observed=false term_sent=false kill_sent=false
  mkdir -p "${evidence:h}"

  if bounded_reap_until "$pid" "$natural_ms"; then
    natural_observed=true
    outcome=natural_exit
  else
    wait_status=$?
    if (( wait_status != 1 )); then
      bounded_reap_contain_clock_failure \
        "$pid" "$evidence" "$label" "$natural_ms" "$term_ms" "$kill_ms" \
        natural_wait "$start_ns"
      return $?
    fi
    forced=TERM
    term_sent=true
    kill -TERM "$pid" 2>/dev/null || true
    if bounded_reap_until "$pid" "$term_ms"; then
      outcome=terminated
    else
      wait_status=$?
      if (( wait_status != 1 )); then
        bounded_reap_contain_clock_failure \
          "$pid" "$evidence" "$label" "$natural_ms" "$term_ms" "$kill_ms" \
          term_wait "$start_ns"
        return $?
      fi
      forced=KILL
      kill_sent=true
      kill -KILL "$pid" 2>/dev/null || true
      if bounded_reap_until "$pid" "$kill_ms"; then
        outcome=killed
      else
        wait_status=$?
        if (( wait_status != 1 )); then
          bounded_reap_contain_clock_failure \
            "$pid" "$evidence" "$label" "$natural_ms" "$term_ms" "$kill_ms" \
            kill_wait "$start_ns"
          return $?
        fi
      fi
    fi
  fi

  if [[ "$outcome" != unreaped ]]; then
    if wait "$pid"; then exit_code=0; else exit_code=$?; fi
  fi
  end_ns=$(bounded_reap_now_ns) || {
    bounded_reap_write_evidence \
      "$evidence" "$label" "$pid" "$start_ns" unavailable unavailable \
      "$natural_ms" "$term_ms" "$kill_ms" \
      "$natural_observed" "$term_sent" "$kill_sent" \
      "$forced" "$outcome" "$exit_code" true end
    return 127
  }
  [[ "$end_ns" == <-> ]] || {
    bounded_reap_write_evidence \
      "$evidence" "$label" "$pid" "$start_ns" unavailable unavailable \
      "$natural_ms" "$term_ms" "$kill_ms" \
      "$natural_observed" "$term_sent" "$kill_sent" \
      "$forced" "$outcome" "$exit_code" true end_invalid
    return 127
  }
  bounded_reap_write_evidence \
    "$evidence" "$label" "$pid" "$start_ns" "$end_ns" \
    "$(( (end_ns - start_ns) / 1000000 ))" \
    "$natural_ms" "$term_ms" "$kill_ms" \
    "$natural_observed" "$term_sent" "$kill_sent" \
    "$forced" "$outcome" "$exit_code" false none

  [[ "$outcome" != unreaped ]] || return 124
  return "$exit_code"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file ]]; then
  print -u2 -- "bounded_reap.sh must be sourced by the child-owning zsh"
  exit 64
fi
