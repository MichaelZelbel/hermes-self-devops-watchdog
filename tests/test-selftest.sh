#!/usr/bin/env bash
# The healer liveness probe, driven through the cases that matter, with a stub
# hermes and a stub notifier. No network, no real Hermes, safe anywhere.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/wd" "$W/state" "$W/log"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# Stub notifier: appends every alert to a file.
cat > "$W/bin/notify.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$NOTIFY_LOG"
EOF
chmod +x "$W/bin/notify.sh"
export NOTIFY_LOG="$W/alerts.txt"

# Stub hermes: behaviour chosen by STUB_MODE; always exits 0, as the real
# one-shot does when it reached no model at all.
cat > "$W/bin/hermes" <<'EOF'
#!/usr/bin/env bash
case "${STUB_MODE:-ok}" in
  ok)      echo "session_id: 20260902_abcdef"; echo "ok" ;;
  ratelim) echo "API call failed after 3 retries: HTTP 429: Rate limit reached for this account." ;;
  expired) echo "Error: unauthorized: token expired eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.secretpart" ;;
  silent)  sleep 5 ;;
  nocreds) echo "hermes -z: agent failed: No Codex credentials stored. Run \`hermes auth\` to authenticate."; exit 1 ;;
esac
exit 0
EOF
chmod +x "$W/bin/hermes"

run() { # $1 mode
  STUB_MODE="$1" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W/wd" PROBE_TIMEOUT=2 \
  LOG_FILE="$W/log/selftest.log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" ALERT_EVERY=3600 \
  bash "$HERE/templates/selftest.sh" >/dev/null 2>&1; echo $?
}

# 1. The healer answers: exit 0, no alert.
: > "$NOTIFY_LOG"
[ "$(run ok)" = "0" ] && ok "1 the healer answering one word is exit 0" || bad "1 answering healer was not exit 0"
[ ! -s "$NOTIFY_LOG" ] && ok "2 and a healthy probe sends nothing" || bad "2 a healthy probe alerted" "$(cat "$NOTIFY_LOG")"

# 3. A rate-limited one-shot that EXITS 0 is still judged down, from its output.
: > "$NOTIFY_LOG"
[ "$(run ratelim)" = "20" ] && ok "3 a one-shot that reached no model (exit 0, error on stdout) is judged DOWN" || bad "3 the exit code was trusted"
grep -q "SELF-HEALING IS DOWN" "$NOTIFY_LOG" && ok "4 the alert leads with SELF-HEALING IS DOWN" || bad "4 no SELF-HEALING line" "$(cat "$NOTIFY_LOG")"
grep -q "HTTP 429" "$NOTIFY_LOG" && ok "5 and carries the model's own error line" || bad "5 the reason is missing" "$(cat "$NOTIFY_LOG")"
grep -q "hermes auth add" "$NOTIFY_LOG" && ok "6 and says where the fix lands" || bad "6 no fix sentence"

# 7. While down, the next failure inside ALERT_EVERY does not alert again.
n1=$(grep -c "SELF-HEALING" "$NOTIFY_LOG"); run ratelim >/dev/null; n2=$(grep -c "SELF-HEALING" "$NOTIFY_LOG")
[ "$n1" = "$n2" ] && ok "7 a second failure inside the alert interval is silent (no pager storm)" || bad "7 alerted twice" "$n1 -> $n2"

# 8. Recovery clears the marker and says so once.
run ok >/dev/null
grep -q "repaired" "$NOTIFY_LOG" && ok "8 recovery sends one 'repaired' line" || bad "8 no recovery message" "$(cat "$NOTIFY_LOG")"
[ ! -f "$W/state/selftest.down-since" ] && ok "9 and clears the down marker" || bad "9 marker still there"

# 10. A token in the error text never reaches the alert.
: > "$NOTIFY_LOG"; rm -f "$W/state/selftest.down-since" "$W/state/selftest.last-alert"
run expired >/dev/null
grep -q "secretpart" "$NOTIFY_LOG" && bad "10 a token leaked into the alert" "$(cat "$NOTIFY_LOG")" || ok "10 a token-shaped string in the error is redacted before it can alert"
grep -q "\[redacted\]" "$NOTIFY_LOG" && ok "11 and the redaction marker is visible" || bad "11 no redaction marker" "$(cat "$NOTIFY_LOG")"

# 12. No output within the timeout is DOWN too, with a reason that says so.
: > "$NOTIFY_LOG"; rm -f "$W/state/selftest.down-since" "$W/state/selftest.last-alert"
[ "$(run silent)" = "20" ] && ok "12 a silent healer past the timeout is DOWN" || bad "12 silence passed as healthy"
grep -q "no output within" "$NOTIFY_LOG" && ok "13 and the alert says it was silence" || bad "13 reason missing" "$(cat "$NOTIFY_LOG")"

# 14. No hermes binary at all.
: > "$NOTIFY_LOG"; rm -f "$W/state/selftest.down-since" "$W/state/selftest.last-alert"
rc=$(HERMES_BIN="$W/bin/none" WATCHDOG_HOME="$W/wd" LOG_FILE="$W/log/s.log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" bash "$HERE/templates/selftest.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = "20" ] && grep -q "no hermes program" "$NOTIFY_LOG" && ok "14 a missing hermes is DOWN and says to reinstall" || bad "14 missing binary not handled" "rc=$rc $(cat "$NOTIFY_LOG")"

# 15. A missing watchdog profile.
: > "$NOTIFY_LOG"; rm -f "$W/state/selftest.down-since" "$W/state/selftest.last-alert"
rc=$(HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W/nope" LOG_FILE="$W/log/s.log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" bash "$HERE/templates/selftest.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = "20" ] && grep -q "hermes profile create watchdog" "$NOTIFY_LOG" && ok "15 a missing profile is DOWN and names the command" || bad "15 missing profile not handled"

# 15b. Hermes 0.21.0's own missing-credential line, with exit 1: DOWN, and the reason is that line.
: > "$NOTIFY_LOG"; rm -f "$W/state/selftest.down-since" "$W/state/selftest.last-alert"
[ "$(run nocreds)" = "20" ] && grep -q "No Codex credentials stored" "$NOTIFY_LOG" && ok "15b the missing-credential wording is DOWN and quoted in the alert (Run 10, 2026-09-02)" || bad "15b missing credentials not reported with the reason" "$(cat "$NOTIFY_LOG")"

# 16. OPERATOR_CMD: the probe runs THROUGH the prefix (root's cron over a service user).
cat > "$W/bin/prefix.sh" <<'EOF'
#!/usr/bin/env bash
echo "prefix-used $*" >> "$PREFIX_LOG"
exec "$@"
EOF
chmod +x "$W/bin/prefix.sh"; export PREFIX_LOG="$W/prefix.log"; : > "$PREFIX_LOG"
rc=$(STUB_MODE=ok OPERATOR_CMD="$W/bin/prefix.sh" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W/does-not-exist-for-root" PROBE_TIMEOUT=2 LOG_FILE="$W/log/s.log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" bash "$HERE/templates/selftest.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && grep -q "prefix-used .*hermes -z" "$PREFIX_LOG" && ok "16 OPERATOR_CMD runs the one-shot through the prefix, and a profile dir unreadable to root is not a failure" || bad "16 OPERATOR_CMD not honoured" "rc=$rc $(cat "$PREFIX_LOG")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
