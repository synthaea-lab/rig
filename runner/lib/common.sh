# Shared by the rig's bash scripts; source it, do not run it. Holds the exit-code convention
# every rig tool follows (CONTRIBUTING.md, "Exit codes"), so a caller such as rig.py, CI or
# a shell loop can tell a failed check from a run that could not start:
#
#   0  OK
#   1  the task ran and something failed (a scenario FAILed or ERRORed, a check found a
#      problem, the build produced no usable agent)
#   2  the task could not run: a usage error (unknown option, missing value, unknown name)
#      or an unmet environment (a missing tool, checkout, build or permission)
#
# Messages go to stderr, prefixed with the script's name (run-scenarios, agent-build).
# shellcheck shell=bash

RIG_SCRIPT=$(basename "$0" .sh)

# The task ran and failed.
die() { echo "$RIG_SCRIPT: $*" >&2; exit 1; }

# The command line is wrong; the message says how.
die_usage() { echo "$RIG_SCRIPT: $*" >&2; exit 2; }

# Something the task needs is missing; the message says how to provide it.
die_env() { echo "$RIG_SCRIPT: $*" >&2; exit 2; }

# need_values OPTION "NAME ..." VALUE...: a usage error unless OPTION got one non-empty value
# per NAME. Call it as `need_values "$1" "SNAPSHOT SIDECAR RC" "${@:2:3}"` from an option loop.
need_values() {
  local option=$1 names value
  read -ra names <<< "$2"
  shift 2
  [ $# -eq "${#names[@]}" ] || die_usage "$option needs ${names[*]} (see --help)"
  for value in "$@"; do
    [ -n "$value" ] || die_usage "$option needs ${names[*]} (see --help)"
  done
}
