#!/usr/bin/env bash
# run-prompt.sh judges an operator one-shot by its output, not its exit code.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/log"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

cat > "$W/bin/notify.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$NOTIFY_LOG"
EOF
cat > "$W/bin/hermes" <<'EOF'
#!/usr/bin/env bash
# $2 is the prompt text; record its first line so the test can see it arrived
printf '%s\n' "$2" | head -1 > "$STUB_PROMPT"
case "${STUB_MODE:-ok}" in
  ok)      echo "Hermes DevOps: OK. Self-check: healer answered. What I checked: ..." ;;
  ratelim) echo "API call failed after 3 retries: HTTP 429: Rate limit reached for this account." ;;
  empty)   : ;;
esac
exit 0
EOF
chmod +x "$W/bin/"*
export NOTIFY_LOG="$W/alerts.txt" STUB_PROMPT="$W/prompt.txt"
run() { STUB_MODE="$1" REPO="$HERE" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W" LOG_DIR="$W/log" NOTIFY="$W/bin/notify.sh" RUN_TIMEOUT=5 bash "$HERE/templates/run-prompt.sh" "${2:-hourly-quick-repair}" >/dev/null 2>&1; echo $?; }

: > "$NOTIFY_LOG"
[ "$(run ok)" = "0" ] && ok "1 a run that answered is exit 0" || bad "1 good run failed"
grep -q "^# Prompt: Hermes Hourly Quick Repair" "$STUB_PROMPT" && ok "2 the prompt file's text is what the one-shot receives" || bad "2 prompt not passed" "$(cat "$STUB_PROMPT")"
[ ! -s "$NOTIFY_LOG" ] && ok "3 a good run sends nothing itself (the operator reports through notify.sh)" || bad "3 wrapper alerted on success"
grep -q "Hermes DevOps: OK" "$W/log/hourly-quick-repair.log" && ok "4 the full output is logged" || bad "4 output not logged"

[ "$(run ratelim)" = "20" ] && grep -q "SELF-HEALING IS DOWN" "$NOTIFY_LOG" && ok "5 an API failure (exit 0 from hermes) is reported as self-healing down" || bad "5 API failure swallowed" "$(cat "$NOTIFY_LOG")"
: > "$NOTIFY_LOG"
[ "$(run empty)" = "20" ] && grep -q "no output" "$NOTIFY_LOG" && ok "6 no output is reported, not treated as quiet health" || bad "6 empty output passed"
[ "$(run ok nonsense)" = "2" ] && ok "7 an unknown prompt name is refused" || bad "7 unknown prompt accepted"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
