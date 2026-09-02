#!/usr/bin/env bash
# ==============================================================================
# Hermes Self Watchdog: the healer liveness probe.
#
# Asks the watchdog Hermes to say one word. If it cannot, the healer is down,
# and every repair the operator layer would file goes nowhere. This is the
# check the August 2026 incident lacked: eight days of green reports while a
# shared, expired sign-in killed every repair job at login.
#
# Exit codes:
#   0  the healer answered
#   20 the healer did not answer (alert sent, if notify.sh is reachable)
#
# JUDGED BY OUTPUT, NOT BY EXIT CODE. `hermes -z` exits 0 when it reached no
# model at all; the error goes to stdout. So the probe looks for the word.
#
# Overrides (env vars):
#   HERMES_BIN        hermes CLI (default: ~/.local/bin/hermes)
#   WATCHDOG_HOME     HERMES_HOME of the watchdog profile
#                     (default: ~/.hermes/profiles/watchdog)
#   PROBE_TIMEOUT     seconds allowed for the answer (default: 120)
#   LOG_FILE          (default: /var/log/hermes-watchdog/selftest.log)
#   STATE_DIR         (default: /var/lib/hermes-watchdog)
#   NOTIFY            path to notify.sh (default: beside this script)
#   ALERT_EVERY       re-alert interval while down, seconds (default: 21600)
#   OPERATOR_CMD      prefix that runs a command AS the gateway user with the
#                     watchdog profile selected, for a floor that runs from
#                     root's cron over a service user's Hermes, e.g.
#                     "sudo -n -u ai -H env HERMES_HOME=/home/ai/.hermes/profiles/watchdog"
#                     (default: empty; run directly with HERMES_HOME=WATCHDOG_HOME)
# ==============================================================================

set -uo pipefail

HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
WATCHDOG_HOME="${WATCHDOG_HOME:-$HOME/.hermes/profiles/watchdog}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-120}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-watchdog/selftest.log}"
STATE_DIR="${STATE_DIR:-/var/lib/hermes-watchdog}"
NOTIFY="${NOTIFY:-$(dirname "$0")/notify.sh}"
ALERT_EVERY="${ALERT_EVERY:-21600}"
OPERATOR_CMD="${OPERATOR_CMD:-}"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" 2>/dev/null || true
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }

# Redact anything that looks like a bearer token or key before it can reach a
# log or an alert. The probe's output is model text; it should never carry a
# secret, and this makes sure a surprising error message cannot either.
redact() { sed -E 's/(sk-|eyJ|ghp_|xox[a-z]-)[A-Za-z0-9._-]{8,}/\1[redacted]/g'; }

alert() {
  # Rate-limited: one alert when it goes down, then one every ALERT_EVERY.
  local stamp="$STATE_DIR/selftest.down-since" now last
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    last="$(cat "$STATE_DIR/selftest.last-alert" 2>/dev/null || echo 0)"
    [ $((now - last)) -ge "$ALERT_EVERY" ] || return 0
  else
    printf '%s\n' "$now" > "$stamp"
  fi
  printf '%s\n' "$now" > "$STATE_DIR/selftest.last-alert"
  if [ -x "$NOTIFY" ]; then
    printf '%s\n' "$1" | "$NOTIFY" >> "$LOG_FILE" 2>&1 || log "notify failed"
  fi
}

recovered() {
  if [ -f "$STATE_DIR/selftest.down-since" ]; then
    rm -f "$STATE_DIR/selftest.down-since" "$STATE_DIR/selftest.last-alert"
    log "healer answered again; clearing the down marker"
    [ -x "$NOTIFY" ] && printf '%s\n' "Hermes DevOps: repaired. Self-check: the healer answers again." | "$NOTIFY" >> "$LOG_FILE" 2>&1
  fi
}

if [ ! -x "$HERMES_BIN" ]; then
  msg="SELF-HEALING IS DOWN: there is no hermes program at $HERMES_BIN, so every repair job this watchdog files goes into a queue nothing can run. Reinstall Hermes as the gateway user."
  log "$msg"; alert "$msg"; exit 20
fi

if [ -z "$OPERATOR_CMD" ] && [ ! -d "$WATCHDOG_HOME" ]; then
  msg="SELF-HEALING IS DOWN: the watchdog profile is missing at $WATCHDOG_HOME. Run: hermes profile create watchdog"
  log "$msg"; alert "$msg"; exit 20
fi

# shellcheck disable=SC2086  # OPERATOR_CMD is a deliberate word-split prefix
if [ -n "$OPERATOR_CMD" ]; then
  out="$(cd / && timeout "$PROBE_TIMEOUT" $OPERATOR_CMD "$HERMES_BIN" -z "reply with the single word: ok" </dev/null 2>&1 | redact)"
else
  out="$(cd / && HERMES_HOME="$WATCHDOG_HOME" timeout "$PROBE_TIMEOUT" "$HERMES_BIN" -z "reply with the single word: ok" </dev/null 2>&1 | redact)"
fi
rc=$?

# The word, on its own, somewhere in the output. Session banners and a
# `session_id:` line are normal and ignored.
if printf '%s\n' "$out" | grep -qiwE 'ok'; then
  log "healer answered (rc=$rc)"
  recovered
  exit 0
fi

# rc is informational only, because a failed one-shot exits 0. Say why we
# think it failed from the output, in one line, and where the fix lands.
why="$(printf '%s' "$out" | grep -iE 'failed|error|rate limit|unauthori|expired|no credential|not logged|timed out|timeout' | head -1)"
[ -n "$why" ] || why="$(printf '%s' "$out" | tail -1)"
[ -n "$why" ] || why="no output within ${PROBE_TIMEOUT}s"
msg="SELF-HEALING IS DOWN, so nothing below this line repairs itself: the watchdog Hermes could not answer one word (rc=$rc: ${why}). The floor still restarts a dead gateway, but no diagnosis and no bounded repair will run until this is fixed. If the sign-in expired: as the gateway user, run hermes auth add <provider> --type oauth --no-browser and type the code; the watchdog profile shares that store."
log "$msg"
alert "$msg"
exit 20
