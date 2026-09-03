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
# $2 is the prompt text; record all of it so the test can see what arrived
printf '%s\n' "$2" > "$STUB_PROMPT"
case "${STUB_MODE:-ok}" in
  ok)      echo "Hermes DevOps: OK. Self-check: healer answered. What I checked: ..." ;;
  ratelim) echo "API call failed after 3 retries: HTTP 429: Rate limit reached for this account." ;;
  nocreds) echo "hermes -z: agent failed: No Codex credentials stored. Run \`hermes auth\` to authenticate."; exit 1 ;;
  # A real, healthy deep check from the author's host, 2026-09-03T05:47Z. It
  # reached the model, found the host well and chose to send nothing. Its
  # findings mention a credential, a rate limit and an expired thing, because
  # that is what a DevOps report talks about.
  goodreport)
    echo "Deep check complete at 2026-09-03T05:47:34Z."
    echo ""
    echo "Self-check: healer answered."
    echo ""
    echo "No alert sent. All other findings are unchanged carry-over items."
    echo ""
    echo "Carry-over operator items:"
    echo "1. Outdated gateway service definition; refresh needs a maintenance window."
    echo "2. chrome-bridge MCP keeps failing and is parked."
    echo "3. A provider token has expired and is not logged in on an unused profile."
    echo "4. ttyd PID 405604 still exposes a credential on its command line."
    echo "5. The API call failed rate limit wording appears in last week's log excerpt."
    ;;
  empty)   : ;;
esac
exit 0
EOF
chmod +x "$W/bin/"*
export NOTIFY_LOG="$W/alerts.txt" STUB_PROMPT="$W/prompt.txt"
run() { STUB_MODE="$1" REPO="$HERE" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W" LOG_DIR="$W/log" NOTIFY="$W/bin/notify.sh" RUN_TIMEOUT=5 bash "$HERE/templates/run-prompt.sh" "${2:-hourly-quick-repair}" >/dev/null 2>&1; echo $?; }

: > "$NOTIFY_LOG"
[ "$(run ok)" = "0" ] && ok "1 a run that answered is exit 0" || bad "1 good run failed"
grep -q "^# Prompt: Hermes Hourly Quick Repair" "$STUB_PROMPT" && ok "2 the prompt file's text is what the one-shot receives" || bad "2 prompt not passed" "$(head -1 "$STUB_PROMPT")"
# Every path the operator needs is handed to it, absolute. Relative ones cost the
# author two live runs: a runbook "not found on disk", and an alert downgraded to
# a local note because templates/notify.sh was not where the operator looked.
grep -q "^## Paths on this host" "$STUB_PROMPT" && ok "2a the paths block leads the prompt" || bad "2a no paths block" "$(head -1 "$STUB_PROMPT")"
grep -q "runbook: *$HERE/hermes-devops-runbook.md" "$STUB_PROMPT" && ok "2b the runbook is named absolutely" || bad "2b runbook path not absolute"
grep -q "send an alert: *$W/bin/notify.sh" "$STUB_PROMPT" && ok "2c the alert command is named absolutely" || bad "2c notify path not absolute"
grep -q "the floor's log: *$HERE/.state/floor.log" "$STUB_PROMPT" && ok "2d the floor's own log is named, not a foreign one" || bad "2d floor log not named"
grep -q "this run's log: *$W/log/hourly-quick-repair.log" "$STUB_PROMPT" && ok "2e the run log is named, so the operator can avoid repeating itself" || bad "2e run log not named"
[ ! -s "$NOTIFY_LOG" ] && ok "3 a good run sends nothing itself (the operator reports through notify.sh)" || bad "3 wrapper alerted on success"
grep -q "Hermes DevOps: OK" "$W/log/hourly-quick-repair.log" && ok "4 the full output is logged" || bad "4 output not logged"

[ "$(run ratelim)" = "20" ] && grep -q "SELF-HEALING IS DOWN" "$NOTIFY_LOG" && ok "5 an API failure (exit 0 from hermes) is reported as self-healing down" || bad "5 API failure swallowed" "$(cat "$NOTIFY_LOG")"
: > "$NOTIFY_LOG"
[ "$(run empty)" = "20" ] && grep -q "no output" "$NOTIFY_LOG" && ok "6 no output is reported, not treated as quiet health" || bad "6 empty output passed"
: > "$NOTIFY_LOG"
[ "$(run nocreds)" = "20" ] && grep -q "SELF-HEALING IS DOWN" "$NOTIFY_LOG" && ok "8 the missing-credential wording Hermes 0.21.0 prints (exit 1) is judged down (Run 10, 2026-09-02)" || bad "8 the credentials-missing run passed as a good run" "$(cat "$NOTIFY_LOG")"
[ "$(run ok nonsense)" = "2" ] && ok "7 an unknown prompt name is refused" || bad "7 unknown prompt accepted"
# A healthy report that TALKS about credentials, rate limits and expiry is a
# healthy report. On 2026-09-03 the loose pattern turned exactly this run into
# "SELF-HEALING IS DOWN ... did not reach a model" and sent it to the operator.
: > "$NOTIFY_LOG"
[ "$(run goodreport six-hour-deep-check)" = "0" ] && [ ! -s "$NOTIFY_LOG" ] && ok "9 a healthy report that mentions a credential is not called a failure" || bad "9 the operator's own findings were read as the runner's error" "$(cat "$NOTIFY_LOG")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
