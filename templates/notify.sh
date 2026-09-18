#!/usr/bin/env bash
# ==============================================================================
# Hermes Self Watchdog: the one way the kit reaches a human, and the policy that
# decides whether it should.
#
# THE POLICY (docs/alerts.md, and the reason for the 2026-09-13 rewrite)
# -----------------------------------------------------------------------------
# A watchdog that fixed something by itself has nothing to ask a human. On the
# kit's own host, every self-repaired restart produced a message ("the gateway
# hiccupped, the floor restarted it"), the operator escalated the same recurring
# fault several times a day, and the human counted a hundred messages in one day
# with nothing in them he had to do. Alert fatigue is measured: acceptance drops
# about 30% per extra reminder (Ancker et al. 2017). So every message now falls
# into one of three classes, decided by its status:
#
#   quiet   recovered on its own / repaired automatically / for the record
#           -> logged, and recorded if a ledger exists. Sent NOWHERE.
#   card    needs a person / warning, not broken yet / alert
#           -> something a human should see, but not tonight. On a hub host it
#              becomes one card on the attention ledger (shown at most once a
#              day, deduplicated per topic); elsewhere it is sent, once per
#              NOTIFY_DEDUP_SECONDS for the same first line.
#   urgent  still down, needs you / self-repair is down, needs you
#           -> sent now, always.
#
# The status comes from NOTIFY_STATUS when the caller sets it, else from the
# words of the message (the case block below). A caller that knows better says
# so: NOTIFY_STATUS="repaired automatically" notify.sh "...".
#
# THE SENDER
# -----------------------------------------------------------------------------
#   hub-notify   present on a hub host (/usr/local/bin/hub-notify): the hub's
#                one sanctioned sender. Its bot lane hands the FACTS to the hub
#                bot, which writes the message itself so a reply lands in a
#                conversation that can answer; its card and record lanes are the
#                quiet classes above. No bot token is read or passed here.
#   hermes send  everywhere else: reuses the platform credentials the gateway
#                already holds. No model, no agent loop, no token copied.
#
# Usage:  printf '%s\n' "message" | notify.sh
#         notify.sh "message"
#
# Overrides (env vars):
#   NOTIFY_SENDER   auto (default) | hub-notify | hermes-send
#   NOTIFY_STATUS   how it ended, one of the statuses above (else derived)
#   NOTIFY_QUIET    comma list of statuses that are logged only
#                   (default "recovered on its own,repaired automatically,for the record")
#   NOTIFY_URGENT   comma list of statuses that are sent at once
#                   (default "still down, needs you|self-repair is down, needs you", '|' separated)
#   NOTIFY_DEDUP_SECONDS  card class, hermes-send: same first line at most once
#                   in this window (default 86400; 0 disables)
#   NOTIFY_TOPIC    hub-notify card lane: one open card per topic per day
#                   (default hermes-watchdog)
#   NOTIFY_PROFILE / NOTIFY_ROUTE / NOTIFY_SOURCE   hub-notify bot lane (hub, watchdog, hermes-self-ops-kit)
#   HUB_NOTIFY      path of hub-notify (default /usr/local/bin/hub-notify)
#   NOTIFY_SUDO     how a non-root caller crosses to hub-notify: auto (default: only
#                   through a sudo rule that already exists) | "" never | "sudo -n" always
#   HERMES_BIN      hermes CLI (default: ~/.local/bin/hermes)
#   SEND_HOME       HERMES_HOME that holds the platform credentials (default ~/.hermes)
#   ALERT_TARGET    `hermes send -t` target (default: telegram)
#   SUBJECT         header line for hermes send (default: "Hermes watchdog")
#   SEND_CMD        prefix that runs hermes send AS the gateway user when the
#                   caller is root, e.g. "sudo -n -u ai -H" (default: empty)
#   LOG_FILE        the notify log (default /var/log/hermes-watchdog/notify.log)
#   STATE_DIR       dedup state (default /var/lib/hermes-watchdog, else ~/.local/state/hermes-watchdog)
#
# Exit codes: 0 handled (sent, carded, or deliberately kept quiet);
#             30 not delivered (the reason is on stderr and in the log).
# ==============================================================================

set -uo pipefail

NOTIFY_SENDER="${NOTIFY_SENDER:-auto}"
NOTIFY_QUIET="${NOTIFY_QUIET:-recovered on its own,repaired automatically,for the record}"
NOTIFY_URGENT="${NOTIFY_URGENT:-still down, needs you|self-repair is down, needs you}"
NOTIFY_DEDUP_SECONDS="${NOTIFY_DEDUP_SECONDS:-86400}"
NOTIFY_TOPIC="${NOTIFY_TOPIC:-hermes-watchdog}"
HUB_NOTIFY="${HUB_NOTIFY:-/usr/local/bin/hub-notify}"
NOTIFY_PROFILE="${NOTIFY_PROFILE:-hub}"
NOTIFY_ROUTE="${NOTIFY_ROUTE:-watchdog}"
NOTIFY_SOURCE="${NOTIFY_SOURCE:-hermes-self-ops-kit}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
SEND_HOME="${SEND_HOME:-$HOME/.hermes}"
ALERT_TARGET="${ALERT_TARGET:-telegram}"
SUBJECT="${SUBJECT:-Hermes watchdog}"
SEND_CMD="${SEND_CMD:-}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-watchdog/notify.log}"
STATE_DIR="${STATE_DIR:-/var/lib/hermes-watchdog}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# The operator's own session calls this as the service user, whose writes into
# root's log directory fail. Fall back to a log the caller can write, and say so
# on stderr, rather than losing the record of an alert.
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/hermes-watchdog/notify.log"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "notify: log falls back to $LOG_FILE (the default is not writable by $(id -un))" >&2
fi
if ! { mkdir -p "$STATE_DIR" && : >> "$STATE_DIR/.w"; } 2>/dev/null; then
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hermes-watchdog"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
fi
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
head120() { printf '%s' "$1" | head -c 120 | tr '\n' ' '; }

if [ $# -gt 0 ]; then body="$*"; else body="$(cat)"; fi
[ -n "$body" ] || { echo "notify: empty message" >&2; exit 30; }

# Never let a secret ride along in an alert.
body="$(printf '%s' "$body" | sed -E 's/(sk-|eyJ|ghp_|xox[a-z]-)[A-Za-z0-9._-]{8,}/\1[redacted]/g')"

# --- How it ended: the status decides the class -------------------------------
status="${NOTIFY_STATUS:-}"
if [ -z "$status" ]; then
  case "$body" in
    *"SELF-HEALING IS DOWN"*)                        status="self-repair is down, needs you" ;;
    *DOWN*|*"still unreachable"*|*"stayed down"*)    status="still down, needs you" ;;
    *"needs the operator"*|*incident*|*Incident*)    status="needs a person" ;;
    *hiccup*)                                        status="repaired automatically" ;;
    *recovered*|*repaired*|*"answers again"*|*resolved*|*"back within"*) status="recovered on its own" ;;
    *"daily summary"*|*"Daily summary"*)             status="for the record" ;;
    *LOW*|*WARN*|*low*|*spike*|*SPIKE*)              status="warning, not broken yet" ;;
    *)                                               status="alert" ;;
  esac
fi
in_list() { # in_list <status> <list> <separator>
  local s="$1" list="$2" sep="$3" item
  while IFS= read -r item; do
    [ "$item" = "$s" ] && return 0
  done < <(printf '%s\n' "$list" | tr "$sep" '\n')  # the newline: read drops a last item without one
  return 1
}
class=card
in_list "$status" "$NOTIFY_QUIET" ',' && class=quiet
in_list "$status" "$NOTIFY_URGENT" '|' && class=urgent

# Reader installations with conversation protection use the same verified source
# boundary as the gateway. Prose and inferred urgency are never sent directly.
CHAT_PROFILE="${HUB_CHAT_PROFILE:-$SEND_HOME}"
CHAT_COMMAND="${HUB_CHAT_COMMAND:-$HOME/.local/bin/hub-chat}"
if [ -f "$CHAT_PROFILE/hub-chat.json" ]; then
  if [ "$class" != "urgent" ]; then
    log "kept local by shared conversation policy ($status)"
    exit 0
  fi
  if [ ! -x "$CHAT_COMMAND" ]; then
    log "critical event retained: shared chat command is unavailable"
    exit 30
  fi
  if "$CHAT_COMMAND" --profile "$CHAT_PROFILE" submit-critical "${NOTIFY_ITEM_ID:-watchdog:gateway}" >> "$LOG_FILE" 2>&1; then
    log "critical source queued for a fresh check; delivery is not yet confirmed"
    exit 0
  fi
  log "critical event could not be queued; no delivery claimed"
  exit 30
fi

# hub-notify reads root-only config, so a caller that is the service user needs a
# way across to it. THAT CROSSING BELONGS TO THE HOST THAT OWNS hub-notify, NEVER TO
# THIS KIT. Until 2026-09-17 this comment said "the kit's install adds the one-line
# sudoers rule for exactly this binary", and the code hopped through `sudo -n`
# unconditionally. No installer in this kit, or in any kit built on it, ever wrote
# that rule: it existed on one host, typed by hand. Everywhere else the hop could only
# fail, and inside a systemd unit that keeps NoNewPrivileges=true sudo cannot start at
# all, however many rules exist. On 2026-09-14 exactly that (a granted rule, a sandbox
# that forbids using it, an error blaming a healthy service) cost the author a phone
# call in front of an audience. So nothing is assumed any more:
#   NOTIFY_SUDO unset or "auto"  hop only if a rule for exactly this binary ALREADY
#                                answers without a password; otherwise call it directly
#   NOTIFY_SUDO=""               never hop (a host that made hub-notify reachable the
#                                right way: a group-owned socket behind the same name)
#   NOTIFY_SUDO="sudo -n"        always hop (the old behaviour, stated out loud)
# When the call fails, its own words go to the log, never a guess about the cause.
NOTIFY_SUDO="${NOTIFY_SUDO-auto}"
runner() {
  RUNNER=("$HUB_NOTIFY")
  [ "$(id -u)" -eq 0 ] && return 0
  local hop="$NOTIFY_SUDO"
  if [ "$hop" = "auto" ]; then
    hop=""
    if command -v sudo >/dev/null 2>&1 && sudo -n -l "$HUB_NOTIFY" >/dev/null 2>&1; then hop="sudo -n"; fi
  fi
  # shellcheck disable=SC2206  # the hop is a deliberate word-split prefix
  [ -n "$hop" ] && RUNNER=($hop "$HUB_NOTIFY")
  return 0
}
sender="$NOTIFY_SENDER"
if [ "$sender" = "auto" ]; then
  if [ -x "$HUB_NOTIFY" ]; then sender=hub-notify; else sender=hermes-send; fi
fi

# --- quiet: it fixed itself; nobody's phone rings -----------------------------
if [ "$class" = "quiet" ]; then
  if [ "$sender" = "hub-notify" ]; then
    runner
    why="$(printf '%s\n' "$body" | "${RUNNER[@]}" --lane record --source "$NOTIFY_SOURCE" --summary "$status" 2>&1 >/dev/null)" \
      && log "kept quiet ($status), recorded on the ledger: $(head120 "$body")" \
      || log "kept quiet ($status), ledger not reached (${RUNNER[*]} said: $(head120 "${why:-nothing}")): $(head120 "$body")"
  else
    log "kept quiet ($status): $(head120 "$body")"
  fi
  exit 0
fi

# --- card: a human should see it, not tonight ---------------------------------
if [ "$class" = "card" ] && [ "$sender" = "hub-notify" ]; then
  runner
  out="$(printf '%s\n' "$body" | "${RUNNER[@]}" --lane card --kind finding --topic "$NOTIFY_TOPIC" --source "$NOTIFY_SOURCE" \
      --title "What the self-repair watchdog reported ($(date -u +%Y-%m-%d))" \
      --what "${NOTIFY_CARD_WHAT:-The self-repair watchdog on the server that runs your AI assistants has a report it could not settle on its own ($status).}" \
      --if-ignored "${NOTIFY_CARD_IF_IGNORED:-It stays unsettled. The watchdog keeps repairing what it can and will not ask again for a day.}" \
      --next "${NOTIFY_CARD_NEXT:-Open the report, then tell the hub bot what you want done, or tell it to leave it.}" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    log "carded ($status): $(head120 "$out") :: $(head120 "$body")"
    exit 0
  fi
  log "card not filed (rc=$rc): $(head120 "$out"); sending on the bot lane instead"
  class=urgent
fi
if [ "$class" = "card" ] && [ "$NOTIFY_DEDUP_SECONDS" -gt 0 ] 2>/dev/null; then
  key="$(printf '%s|%s' "$status" "$(printf '%s' "$body" | head -1)" | cksum | cut -d' ' -f1)"
  stamp="$STATE_DIR/dedup-$key"
  now="$(date +%s)"; last="$(cat "$stamp" 2>/dev/null || echo 0)"
  if [ $((now - last)) -lt "$NOTIFY_DEDUP_SECONDS" ]; then
    log "not repeated ($status, same first line $(( (now - last) / 60 ))m ago): $(head120 "$body")"
    exit 0
  fi
  printf '%s' "$now" > "$stamp" 2>/dev/null || true
fi

# --- send: the bot lane on a hub host, hermes send elsewhere ------------------
if [ "$sender" = "hub-notify" ]; then
  if [ ! -x "$HUB_NOTIFY" ]; then
    log "not sent: no hub-notify at $HUB_NOTIFY"; echo "notify: no hub-notify at $HUB_NOTIFY" >&2; exit 30
  fi
  runner
  out="$("${RUNNER[@]}" --lane bot --profile "$NOTIFY_PROFILE" --route "$NOTIFY_ROUTE" --source "$NOTIFY_SOURCE" \
          --summary "$body" --status "$status" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    note="sent via hub-notify bot lane (profile=$NOTIFY_PROFILE route=$NOTIFY_ROUTE, $status)"
    printf '%s' "$out" | grep -q "falling back to the machine lane" \
      && note="sent on the MACHINE lane; the hub bot could not be reached"
    log "$note: $(head120 "$body")"
    exit 0
  fi
  log "not sent (rc=$rc): $(printf '%s' "$out" | head -c 300 | tr '\n' ' ')"
  printf 'notify: not sent (rc=%s): %s\n' "$rc" "$(printf '%s' "$out" | head -c 300)" >&2
  exit 30
fi

if [ ! -x "$HERMES_BIN" ]; then
  log "not sent: no hermes at $HERMES_BIN"; echo "notify: no hermes at $HERMES_BIN" >&2; exit 30
fi
# `hermes send` prints its own result; a failure is a non-empty error on
# stderr plus a non-zero exit, and we test both so a silent failure cannot
# pass as delivery. SEND_CMD is the hop to the gateway user for a caller that
# is root (root's cron in the root-plus-service-user layout): without it an
# alert from root's clock runs `hermes send` as root over the service user's
# home, which works once and then leaves root-owned files there.
# shellcheck disable=SC2086  # SEND_CMD is a deliberate word-split prefix
if [ -n "$SEND_CMD" ]; then
  out="$(printf '%s\n' "$body" | timeout 60 $SEND_CMD env HERMES_HOME="$SEND_HOME" "$HERMES_BIN" send -t "$ALERT_TARGET" -s "$SUBJECT" 2>&1)"
else
  out="$(printf '%s\n' "$body" | HERMES_HOME="$SEND_HOME" timeout 60 "$HERMES_BIN" send -t "$ALERT_TARGET" -s "$SUBJECT" 2>&1)"
fi
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qiE 'error|failed|no such target|not configured'; then
  log "sent to $ALERT_TARGET ($status): $(head120 "$body")"
  exit 0
fi
log "not sent (rc=$rc): $(printf '%s' "$out" | head -c 300 | tr '\n' ' ')"
printf 'notify: not sent (rc=%s): %s\n' "$rc" "$(printf '%s' "$out" | head -c 300)" >&2
exit 30
