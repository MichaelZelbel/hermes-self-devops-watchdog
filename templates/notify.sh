#!/usr/bin/env bash
# ==============================================================================
# Hermes Self Watchdog: alerts through `hermes send`.
#
# `hermes send` pipes text to any messaging platform Hermes is already
# configured for, reusing the gateway's platform credentials. No model, no
# agent loop, no 4,000-character splitter to maintain, and no bot token copied
# into a second file: the token stays where Hermes keeps it.
#
# Usage:  printf '%s\n' "message" | notify.sh
#         notify.sh "message"
#
# Overrides (env vars):
#   HERMES_BIN     hermes CLI (default: ~/.local/bin/hermes)
#   SEND_HOME      HERMES_HOME that holds the platform credentials
#                  (default: the gateway user's, ~/.hermes)
#   ALERT_TARGET   `hermes send -t` target (default: telegram)
#   SUBJECT        header line (default: "Hermes watchdog")
#   SEND_CMD       prefix that runs hermes send AS the gateway user, for a caller
#                  that is root, e.g. "sudo -n -u ai -H" (default: empty)
#
# Exit codes: 0 sent; 30 not sent (the reason is on stderr and in the log).
# ==============================================================================

set -uo pipefail

HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
SEND_HOME="${SEND_HOME:-$HOME/.hermes}"
ALERT_TARGET="${ALERT_TARGET:-telegram}"
SUBJECT="${SUBJECT:-Hermes watchdog}"
SEND_CMD="${SEND_CMD:-}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-watchdog/notify.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# The operator's own session calls this as the service user, whose writes into
# root's log directory fail. Fall back to a log the caller can write, and say so
# on stderr, rather than losing the record of an alert.
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/hermes-watchdog/notify.log"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "notify: log falls back to $LOG_FILE (the default is not writable by $(id -un))" >&2
fi
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }

if [ $# -gt 0 ]; then body="$*"; else body="$(cat)"; fi
[ -n "$body" ] || { echo "notify: empty message" >&2; exit 30; }

# Never let a secret ride along in an alert.
body="$(printf '%s' "$body" | sed -E 's/(sk-|eyJ|ghp_|xox[a-z]-)[A-Za-z0-9._-]{8,}/\1[redacted]/g')"

if [ ! -x "$HERMES_BIN" ]; then
  log "not sent: no hermes at $HERMES_BIN"; echo "notify: no hermes at $HERMES_BIN" >&2; exit 30
fi

# `hermes send` prints its own result; a failure is a non-empty error on
# stderr plus a non-zero exit, and we test both so a silent failure cannot
# pass as delivery.
out="$(printf '%s\n' "$body" | HERMES_HOME="$SEND_HOME" timeout 60 "$HERMES_BIN" send -t "$ALERT_TARGET" -s "$SUBJECT" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qiE 'error|failed|no such target|not configured'; then
  log "sent to $ALERT_TARGET: $(printf '%s' "$body" | head -c 120 | tr '\n' ' ')"
  exit 0
fi
log "not sent (rc=$rc): $(printf '%s' "$out" | head -c 300 | tr '\n' ' ')"
printf 'notify: not sent (rc=%s): %s\n' "$rc" "$(printf '%s' "$out" | head -c 300)" >&2
exit 30
