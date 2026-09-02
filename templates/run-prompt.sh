#!/usr/bin/env bash
# ==============================================================================
# Hermes Self Watchdog: run one operator prompt as a one-shot under the
# watchdog profile, and judge the run by what came back.
#
# Usage: run-prompt.sh <hourly-quick-repair|six-hour-deep-check|update-maintenance>
#
# `hermes -z` exits 0 whether or not it reached a model, so this wrapper reads
# the output: an API failure line means the operator did not run, and that is
# reported through notify.sh as a self-healing problem, not swallowed.
#
# Overrides (env vars):
#   REPO           this repository's checkout (default: parent of this script's dir)
#   HERMES_BIN     (default: ~/.local/bin/hermes)
#   WATCHDOG_HOME  (default: ~/.hermes/profiles/watchdog)
#   RUN_TIMEOUT    seconds (default: 900)
#   LOG_DIR        (default: /var/log/hermes-watchdog)
#   NOTIFY         (default: beside this script)
#   OPERATOR_CMD   prefix that runs the one-shot AS the gateway user with the watchdog
#                  profile selected (see selftest.sh); default empty
# ==============================================================================

set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
WATCHDOG_HOME="${WATCHDOG_HOME:-$HOME/.hermes/profiles/watchdog}"
RUN_TIMEOUT="${RUN_TIMEOUT:-900}"
LOG_DIR="${LOG_DIR:-/var/log/hermes-watchdog}"
NOTIFY="${NOTIFY:-$(dirname "$0")/notify.sh}"
OPERATOR_CMD="${OPERATOR_CMD:-}"

name="${1:-}"
case "$name" in
  hourly-quick-repair|six-hour-deep-check|update-maintenance) ;;
  *) echo "run-prompt: unknown prompt '$name'" >&2; exit 2 ;;
esac
prompt_file="$REPO/prompts/$name.md"
[ -f "$prompt_file" ] || { echo "run-prompt: missing $prompt_file" >&2; exit 2; }
mkdir -p "$LOG_DIR" 2>/dev/null || true
log="$LOG_DIR/$name.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

redact() { sed -E 's/(sk-|eyJ|ghp_|xox[a-z]-)[A-Za-z0-9._-]{8,}/\1[redacted]/g'; }

# The prompt names the runbook by relative path, so run from the checkout.
# shellcheck disable=SC2086  # OPERATOR_CMD is a deliberate word-split prefix
if [ -n "$OPERATOR_CMD" ]; then
  out="$(cd "$REPO" && timeout "$RUN_TIMEOUT" $OPERATOR_CMD "$HERMES_BIN" -z "$(cat "$prompt_file")" </dev/null 2>&1 | redact)"
else
  out="$(cd "$REPO" && HERMES_HOME="$WATCHDOG_HOME" timeout "$RUN_TIMEOUT" "$HERMES_BIN" -z "$(cat "$prompt_file")" </dev/null 2>&1 | redact)"
fi
rc=$?
{
  printf '%s | run %s (rc=%s)\n' "$(ts)" "$name" "$rc"
  printf '%s\n' "$out"
  printf '%s | end %s\n' "$(ts)" "$name"
} >> "$log"

# The operator did not run at all: say so, as a self-healing problem.
if printf '%s' "$out" | grep -qiE 'API call failed|rate limit reached|no credential|not logged in|unauthori|token expired'; then
  why="$(printf '%s' "$out" | grep -iE 'API call failed|rate limit|credential|logged in|unauthori|expired' | head -1)"
  msg="SELF-HEALING IS DOWN: the $name run did not reach a model ($why). The floor still restarts a dead gateway; no diagnosis ran."
  [ -x "$NOTIFY" ] && printf '%s\n' "$msg" | "$NOTIFY" >>"$log" 2>&1
  exit 20
fi
if [ -z "$out" ]; then
  msg="SELF-HEALING IS DOWN: the $name run produced no output within ${RUN_TIMEOUT}s."
  [ -x "$NOTIFY" ] && printf '%s\n' "$msg" | "$NOTIFY" >>"$log" 2>&1
  exit 20
fi
exit 0
