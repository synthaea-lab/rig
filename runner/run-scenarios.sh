#!/usr/bin/env bash
# The lab's scenario runner, run INSIDE a Linux lab guest after agent-build.sh.
#
#   bash /synthaea/rig/runner/run-scenarios.sh [options] [scenario ...]
#
# For each selected scenario: start the agent standalone on the rules checkout (plus any
# YARA file the scenario brings), wait until its sensor listens, run the scenario script,
# wait for the alerts to settle, snapshot them, stop the agent, and compare what fired with
# the scenario's `.yaml` sidecar. One agent per scenario, so no state or late alert leaks
# from one scenario into the next. Then write a Markdown report.
#
# Normally run by rig.py: `python rig.py run <machine> [scenario ...]`.
#
# Options:
#   (no names)        every `default` scenario of runner/scenarios.conf
#   <name> ...        just these (opt-in ones included)
#   --list            print the catalog with each scenario's expectations, run nothing
#   --check           validate the catalog against the scenarios directory, run nothing
#                     (works on any host with bash: `just test lab` runs it)
#   --machine NAME    machine name for the report (default: the hostname)
#   --scenarios DIR   scenarios directory (default: $SYNTHAEA_ROOT/scenarios/scenarios)
#
# Results per scenario:
#   PASS        every expected technique fired within [min_count, min_count + tolerance],
#               nothing else fired
#   UNEXPECTED  expectations met, but other techniques fired too (listed)
#   FAIL        an expected technique fired too few or too many times
#   ERROR       the agent did not start, or the script exited non-zero
#   SKIP        a need is missing on this guest (command, LSM, kernel version)
# Follow-up alerts (FOLLOW_UPS below: the escalation record the agent adds on top of every
# detection) are listed but never judged, unless a sidecar expects them.
# Exit status: 0 when nothing FAILed or ERRORed.
#
# Environment: SYNTHAEA_ROOT (default /synthaea), RIG_STATE (default ~/synthaea-rig: reads
# build-info from agent-build.sh, writes runs/ and reports/), SYNTHAEA_SOURCE (what the
# sources are, set by rig.py).
set -uo pipefail
# Character-aware ${var:0:n} for clip(): alert messages carry UTF-8 (arrows, dashes).
export LC_ALL=C.UTF-8

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${SYNTHAEA_ROOT:-/synthaea}
STATE=${RIG_STATE:-$HOME/synthaea-rig}
CATALOG=$HERE/scenarios.conf
FOLLOW_UPS=" RESPONSE-ESCALATE "
SCEN_DIR=$ROOT/scenarios/scenarios
MACHINE=$(hostname | sed 's/^synthaea-//')
MODE=run
NAMES=()

while [ $# -gt 0 ]; do
  case $1 in
    --list) MODE=list ;;
    --check) MODE=check ;;
    --machine) MACHINE=${2:?}; shift ;;
    --scenarios) SCEN_DIR=${2:?}; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;/^set -uo/d'; exit 0 ;;
    -*) echo "run-scenarios: unknown option $1 (see --help)" >&2; exit 2 ;;
    *) NAMES+=("$1") ;;
  esac
  shift
done

die() { echo "run-scenarios: $*" >&2; exit 1; }
clip() { local l; while IFS= read -r l; do printf '%s\n' "${l:0:$1}"; done; }   # cut -c splits UTF-8
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; [ "$s" = - ] && s=""; printf '%s' "$s"; }

# --- catalog + sidecars ----------------------------------------------------------------
declare -A C_SET C_ROOT C_NEEDS C_KERNEL C_FLAGS C_ENV C_YARA C_SETTLE C_NOTE
ORDER=()
while IFS='|' read -r name set root needs kernel flags env yara settle note; do
  name=$(trim "$name")
  [ -z "$name" ] && continue
  case $name in \#*) continue ;; esac
  ORDER+=("$name")
  C_SET[$name]=$(trim "$set"); C_ROOT[$name]=$(trim "$root"); C_NEEDS[$name]=$(trim "$needs")
  C_KERNEL[$name]=$(trim "$kernel"); C_FLAGS[$name]=$(trim "$flags"); C_ENV[$name]=$(trim "$env")
  C_YARA[$name]=$(trim "$yara"); C_SETTLE[$name]=$(trim "$settle"); C_NOTE[$name]=$(trim "$note")
done < "$CATALOG"

# Prints `technique|min_count|tolerance` per expected detection of a sidecar. The sidecars
# keep to the documented shape (synthaea-lab/scenarios README), which is all this reads.
expectations() {
  awk '
    /^expected_detections:/ { inb = 1; next }
    inb && /^[^ \t#-]/      { inb = 0 }
    inb {
      line = $0; sub(/#.*/, "", line)
      if (match(line, /technique:[ \t]*/)) {
        if (t != "") print t "|" m "|" o
        t = substr(line, RSTART + RLENGTH); gsub(/^["\047]|["\047]?[ \t]*$/, "", t); m = 1; o = 0
      } else if (match(line, /min_count:[ \t]*/)) { m = substr(line, RSTART + RLENGTH) + 0 }
      else if (match(line, /tolerance:[ \t]*/))   { o = substr(line, RSTART + RLENGTH) + 0 }
    }
    END { if (t != "") print t "|" m "|" o }' "$1"
}

expect_text() {   # one-line summary of a sidecar's expectations
  local out="" t m o
  while IFS='|' read -r t m o; do
    out+="${out:+, }$t ×$m"; [ "$o" -gt 0 ] && out+="(+$o)"
  done < <(expectations "$1")
  printf '%s' "${out:-no alert}"
}

check() {
  local bad=0 n f
  [ -d "$SCEN_DIR" ] || die "no scenarios directory at $SCEN_DIR"
  for n in "${ORDER[@]}"; do
    [ -f "$SCEN_DIR/$n.sh" ] || { echo "catalog: $n has no $SCEN_DIR/$n.sh"; bad=1; }
    if [ -f "$SCEN_DIR/$n.yaml" ]; then
      expectations "$SCEN_DIR/$n.yaml" | grep -q . || { echo "sidecar: $n.yaml has no readable expected_detections"; bad=1; }
    else
      echo "catalog: $n has no $SCEN_DIR/$n.yaml"; bad=1
    fi
    case ${C_SET[$n]} in default|opt-in) ;; *) echo "catalog: $n: set must be default or opt-in"; bad=1 ;; esac
    for f in ${C_YARA[$n]}; do [ -f "$SCEN_DIR/$f" ] || { echo "catalog: $n: no $SCEN_DIR/$f"; bad=1; }; done
  done
  for f in "$SCEN_DIR"/*.sh; do
    n=$(basename "$f" .sh)
    [ -n "${C_SET[$n]:-}" ] || { echo "catalog: $n.sh is not in runner/scenarios.conf (add a row, default or opt-in)"; bad=1; }
  done
  [ "$bad" = 0 ] && echo "run-scenarios: catalog OK (${#ORDER[@]} scenarios, $SCEN_DIR)"
  return "$bad"
}

if [ "$MODE" = check ]; then check; exit; fi
if [ "$MODE" = list ]; then
  printf '%-24s %-8s %s\n' SCENARIO SET EXPECTED
  for n in "${ORDER[@]}"; do
    printf '%-24s %-8s %s\n' "$n" "${C_SET[$n]}" "$(expect_text "$SCEN_DIR/$n.yaml")"
  done
  exit 0
fi

# --- preflight -------------------------------------------------------------------------
check >/dev/null || { check; die "fix the catalog first"; }
[ -f "$STATE/build-info" ] || die "no $STATE/build-info: build first (python rig.py build <machine>)"
AGENT=$(sed -n 's/^agent_bin=//p' "$STATE/build-info")
[ -x "$AGENT" ] || die "agent binary $AGENT missing: build first (python rig.py build <machine>)"
[ -f /etc/synthaea/agent.toml ] || die "/etc/synthaea/agent.toml missing (agent-build.sh installs it)"
[ -d "$ROOT/rules/sigma" ] || die "$ROOT/rules missing: the run uses the rules checkout as content"
sudo -n true 2>/dev/null || die "needs passwordless sudo (the lab boxes have it)"
# The agent's local control socket lives here; without it every run logs an IPC warning.
sudo install -d -m 0755 /run/synthaea

if [ ${#NAMES[@]} -eq 0 ]; then
  for n in "${ORDER[@]}"; do [ "${C_SET[$n]}" = default ] && NAMES+=("$n"); done
fi
for n in "${NAMES[@]}"; do [ -n "${C_SET[$n]:-}" ] || die "unknown scenario '$n' (--list shows them)"; done

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN=$STATE/runs/$STAMP
mkdir -p "$RUN" "$STATE/reports"
KERNEL=$(uname -r)
# Whoever runs this (a lab user over ssh) must not trip detections meant for attackers;
# the agent's own sockets and our sudo calls are part of the measured noise, reported as is.

kernel_ge() { [ "$(printf '%s\n%s\n' "$2" "${1%%-*}" | sort -V | head -n1)" = "$2" ]; }

missing_need() {   # prints the first unmet need of a scenario, if any
  local n=$1 need alt ok
  for need in ${C_NEEDS[$n]}; do
    case $need in
      lsm:*) grep -qw "${need#lsm:}" /sys/kernel/security/lsm 2>/dev/null || { echo "LSM ${need#lsm:} not active (lsm=$(cat /sys/kernel/security/lsm 2>/dev/null))"; return; } ;;
      *) ok=0; for alt in ${need//\// }; do command -v "$alt" >/dev/null 2>&1 && ok=1; done
         [ "$ok" = 1 ] || { echo "command ${need//\// or } not installed"; return; } ;;
    esac
  done
  if [ -n "${C_KERNEL[$n]}" ] && ! kernel_ge "$KERNEL" "${C_KERNEL[$n]}"; then
    echo "kernel $KERNEL < ${C_KERNEL[$n]}"
  fi
}

# The agent runs as root under sudo: the guest user can neither `kill -0` it nor sudo, so
# liveness is read from /proc and every signal goes through sudo, with a bounded wait.
alive() { [ -d "/proc/$1" ]; }
stop_agent() {   # $1 = sudo's pid, $2 = the agent's pid
  local i
  sudo kill -INT "$2" 2>/dev/null
  for i in $(seq 1 15); do alive "$1" || break; sleep 1; done
  alive "$1" && sudo kill -KILL "$2" "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

count_alerts() {   # technique -> count, as `count technique` lines
  grep -o '"technique":"[^"]*"' "$1" 2>/dev/null | sed 's/^"technique":"//; s/"$//' | sort | uniq -c
}

# --- eBPF verifier summary -------------------------------------------------------------
echo "== agent status"
sudo "$AGENT" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$RUN/status.txt"
PROG_OK=$(grep -c 'accepted by the verifier' "$RUN/status.txt")
CHECK_BAD=$(grep -E '^\[[A-Z]+\]' "$RUN/status.txt" | grep -vc '^\[OK\]')
echo "   $PROG_OK programs accepted by the verifier, $CHECK_BAD check(s) not OK"

# --- one scenario ----------------------------------------------------------------------
declare -A R_STATUS R_FIRED R_UNEXP R_FOLLOW R_TIME R_DETAIL
run_one() {
  local n=$1 W=$RUN/$1 reason start sudo_pid agent_pid rc i last size quiet
  mkdir -p "$W/content/rules"
  reason=$(missing_need "$n")
  if [ -n "$reason" ]; then
    R_STATUS[$n]=SKIP; R_DETAIL[$n]="$reason"; R_TIME[$n]=0; R_FIRED[$n]=""; R_UNEXP[$n]=""; R_FOLLOW[$n]=""
    echo "   SKIP: $reason"; return
  fi

  # Content: the rules checkout, plus the scenario's own YARA file(s).
  cp -r "$ROOT/rules/sigma" "$ROOT/rules/yara" "$W/content/rules/" 2>/dev/null
  mkdir -p "$W/content/rules/yara"
  for f in ${C_YARA[$n]}; do cp "$SCEN_DIR/$f" "$W/content/rules/yara/"; done
  chmod -R a+rX "$W"

  start=$(date +%s)
  # shellcheck disable=SC2086
  sudo env RUST_LOG=info "$AGENT" run --standalone --content-dir "$W/content" \
    --alerts "$W/alerts.ndjson" --events "$W/events.jsonl" ${C_FLAGS[$n]} > "$W/agent.log" 2>&1 &
  sudo_pid=$!
  for i in $(seq 1 90); do
    grep -q 'sensor-linux: listening' "$W/agent.log" 2>/dev/null && break
    alive "$sudo_pid" || break
    sleep 1
  done
  agent_pid=$(pgrep -P "$sudo_pid" | head -n1)
  agent_pid=${agent_pid:-$sudo_pid}
  if ! grep -q 'sensor-linux: listening' "$W/agent.log"; then
    stop_agent "$sudo_pid" "$agent_pid"
    R_STATUS[$n]=ERROR; R_DETAIL[$n]="agent did not start (see $W/agent.log)"; R_TIME[$n]=$(( $(date +%s) - start ))
    R_FIRED[$n]=""; R_UNEXP[$n]=""; R_FOLLOW[$n]=""
    echo "   ERROR: agent did not start"; return
  fi
  sleep 1

  local envs=(EVENTS="$W/events.jsonl" ALERTS="$W/alerts.ndjson" AGENT_PID="$agent_pid")
  # shellcheck disable=SC2206
  envs+=(${C_ENV[$n]})
  if [ "${C_ROOT[$n]}" = yes ]; then
    (cd "$W" && timeout 300 sudo env "${envs[@]}" bash "$SCEN_DIR/$n.sh") > "$W/scenario.log" 2>&1
  else
    (cd "$W" && timeout 300 env "${envs[@]}" bash "$SCEN_DIR/$n.sh") > "$W/scenario.log" 2>&1
  fi
  rc=$?

  # Settle: the catalog's delay, then until the alert file has been quiet for 2 s (max 20 s).
  sleep "${C_SETTLE[$n]:-3}"
  last=-1 quiet=0
  for i in $(seq 1 20); do
    size=$(stat -c %s "$W/alerts.ndjson" 2>/dev/null || echo 0)
    if [ "$size" = "$last" ]; then quiet=$((quiet + 1)); [ "$quiet" -ge 2 ] && break; else quiet=0; fi
    last=$size; sleep 1
  done
  # Snapshot BEFORE stopping: the stop signal itself is a T1562.001 against the agent.
  cp "$W/alerts.ndjson" "$W/alerts.snapshot.ndjson" 2>/dev/null || : > "$W/alerts.snapshot.ndjson"
  stop_agent "$sudo_pid" "$agent_pid"
  R_TIME[$n]=$(( $(date +%s) - start ))

  # Compare.
  local -A got=() want=()
  local c t m o fired="" unexp="" follow="" fail="" status
  while read -r c t; do [ -n "$t" ] && got[$t]=$c; done < <(count_alerts "$W/alerts.snapshot.ndjson")
  while IFS='|' read -r t m o; do
    want[$t]=1
    c=${got[$t]:-0}
    fired+="${fired:+, }$t ×$c"
    if [ "$c" -lt "$m" ]; then fail+="${fail:+; }$t fired $c×, needs ≥$m"
    elif [ "$c" -gt $((m + o)) ]; then fail+="${fail:+; }$t fired $c×, allows ≤$((m + o))"
    fi
  done < <(expectations "$SCEN_DIR/$n.yaml")
  for t in $(printf '%s\n' "${!got[@]}" | sort); do
    [ -n "${want[$t]:-}" ] && continue
    case $FOLLOW_UPS in *" $t "*) follow+="${follow:+, }$t ×${got[$t]}" ;; *) unexp+="${unexp:+, }$t ×${got[$t]}" ;; esac
  done
  if [ -n "$fail" ]; then status=FAIL
  elif [ "$rc" -ne 0 ]; then status=ERROR; fail="script exited $rc"
  elif [ -n "$unexp" ]; then status=UNEXPECTED
  else status=PASS
  fi
  [ "$status" = FAIL ] && [ "$rc" -ne 0 ] && fail+="; script exited $rc"
  # A scenario that checks its own side says why it failed: keep those lines.
  if [ "$rc" -ne 0 ]; then
    local why
    why=$(grep -iE '(^|[[:space:]])(FAIL|ERROR)' "$W/scenario.log" | head -n 5 | sed 's/^[[:space:]]*//')
    [ -n "$why" ] && fail+=$'\n\nScenario output:\n\n'"$(printf '%s\n' "$why" | sed 's/^/    /')"
  fi
  R_STATUS[$n]=$status; R_FIRED[$n]=$fired; R_UNEXP[$n]=$unexp; R_FOLLOW[$n]=$follow; R_DETAIL[$n]=$fail
  echo "   $status  fired: ${fired:-none}${unexp:+  | unexpected: $unexp}${fail:+  | ${fail%%$'\n'*}}"
}

T0=$(date +%s)
for n in "${NAMES[@]}"; do
  echo "== $n"
  run_one "$n"
done
TOTAL=$(( $(date +%s) - T0 ))

# --- report ----------------------------------------------------------------------------
. /etc/os-release
DATE=$(date -u +%F)
REPORT=$STATE/reports/$DATE-$MACHINE.md
info() { sed -n "s/^$1=//p" "$STATE/build-info"; }
fmt_time() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
declare -A TALLY=()
for n in "${NAMES[@]}"; do TALLY[${R_STATUS[$n]}]=$(( ${TALLY[${R_STATUS[$n]}]:-0} + 1 )); done
summary=""
for s in PASS UNEXPECTED FAIL ERROR SKIP; do [ -n "${TALLY[$s]:-}" ] && summary+="${summary:+ · }$s ${TALLY[$s]}"; done
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null || echo "musl")
lsms=$(cat /sys/kernel/security/lsm 2>/dev/null || echo "?")
# ort-compat (or a hand-made equivalent) pins a next release for the C/C++ runtime and drags
# base-files along, so os-release then names the next release: say so, the kernel is the row.
compat=$(sed -n 's/^Pin: release n=//p' /etc/apt/preferences.d/* 2>/dev/null | sort -u | tr '\n' ' ')
distro="${PRETTY_NAME:-?}"
[ -n "$compat" ] && distro+=" (C/C++ runtime partially upgraded from ${compat% } by ort-compat; os-release follows base-files)"
cell() { local s=${1:-—}; s=${s//|/\\|}; printf '%s' "$s"; }

{
  echo "# Lab run: $MACHINE, $DATE"
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| Machine | \`$MACHINE\` ($(hostname)), $distro |"
  echo "| Kernel | \`$KERNEL\` ($(uname -m)), LSMs \`$lsms\`, $glibc |"
  echo "| Agent build | \`$(info agent_bin)\`, $(info profile), ONNX Runtime $(info ort), offline=$(info offline), built $(info built_at) in $(fmt_time "$(info build_seconds)") with $(info rustc) |"
  echo "| Sources at build | $(cell "$(info source)") |"
  echo "| Sources at run | $(cell "${SYNTHAEA_SOURCE:-unknown}") |"
  echo "| eBPF verifier | $PROG_OK programs accepted; $CHECK_BAD status check(s) not OK |"
  echo "| Run | $(date -u +%H:%M) UTC, ${#NAMES[@]} scenarios in $(fmt_time "$TOTAL"), one standalone agent per scenario, content = \`rules/\` |"
  echo
  echo "**$summary**"
  echo
  echo "| Scenario | Result | Expected (sidecar) | Fired | Unexpected | Time |"
  echo "| --- | --- | --- | --- | --- | --- |"
  for n in "${NAMES[@]}"; do
    echo "| \`$n\` | ${R_STATUS[$n]} | $(cell "$(expect_text "$SCEN_DIR/$n.yaml")") | $(cell "${R_FIRED[$n]}") | $(cell "${R_UNEXP[$n]}") | ${R_TIME[$n]}s |"
  done
  echo
  echo "## Details"
  for n in "${NAMES[@]}"; do
    echo
    echo "### \`$n\`: ${R_STATUS[$n]}"
    [ -n "${R_DETAIL[$n]}" ] && echo && echo "${R_DETAIL[$n]}"
    [ -n "${R_FOLLOW[$n]}" ] && echo && echo "Follow-up alerts (not judged): ${R_FOLLOW[$n]}"
    [ -n "${C_NOTE[$n]}" ] && echo && echo "Runner note: ${C_NOTE[$n]}"
    if [ -s "$RUN/$n/alerts.snapshot.ndjson" ]; then
      echo
      echo '```'
      sed 's/.*"technique":"\([^"]*\)","message":"\(.*\)"}$/\1  \2/' "$RUN/$n/alerts.snapshot.ndjson" | clip 220
      echo '```'
    fi
  done
  echo
  echo "## eBPF verifier (\`agent status\`)"
  echo
  echo '```'
  grep -E '^\[' "$RUN/status.txt" | grep -v 'accepted by the verifier'
  echo "... $PROG_OK programs accepted by the verifier"
  grep -E '^\[' "$RUN/status.txt" | grep -v '^\[OK\]' || true
  echo '```'
  echo
  echo "## Agent warnings"
  echo
  echo "Distinct WARN/ERROR lines the agent logged across the run (timestamps stripped):"
  echo
  echo '```'
  cat "$RUN"/*/agent.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\S+Z +(WARN|ERROR)' \
    | sed -E 's/^\S+Z +//; s/pid=[0-9]+/pid=N/g' | clip 200 | sort | uniq -c | sort -rn | head -20
  echo '```'
  echo
  echo "Raw material (agent.log, scenario.log, alerts, events per scenario): \`$RUN\` in the guest."
} > "$REPORT"

echo
echo "== $summary in $(fmt_time "$TOTAL")"
echo "REPORT: $REPORT"
[ -z "${TALLY[FAIL]:-}" ] && [ -z "${TALLY[ERROR]:-}" ]
