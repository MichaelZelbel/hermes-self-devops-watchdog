#!/usr/bin/env bash
# selftest.sh and run-prompt.sh run their Hermes one-shot through agent-cage
# (kit-bootstrap) when the host has it, and work exactly as before when it does
# not. A stub cage records how it was called and then runs the command, so the
# test needs no root and no systemd. The cron example cages the agent jobs.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/wd" "$W/state" "$W/log"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

cat > "$W/bin/notify.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$NOTIFY_LOG"
EOF
cat > "$W/bin/hermes" <<'EOF'
#!/usr/bin/env bash
case "${STUB_MODE:-ok}" in
  ok)   echo "ok" ;;
  slow) echo "Deep check in progress."; sleep 30 ;;
esac
exit 0
EOF
# The stub cage: write down its arguments, then run what follows `--`.
cat > "$W/bin/agent-cage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAGE_LOG"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
chmod +x "$W/bin/"*
export NOTIFY_LOG="$W/alerts.txt" CAGE_LOG="$W/cage.txt"

selftest() { # $1 mode, $2 cage binary ("" = off)
  STUB_MODE="$1" AGENT_CAGE_BIN="$2" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W/wd" PROBE_TIMEOUT=2 \
  LOG_FILE="$W/log/selftest.log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" ALERT_EVERY=3600 \
  bash "$HERE/templates/selftest.sh" >/dev/null 2>&1; echo $?
}
runprompt() { # $1 mode, $2 cage binary
  STUB_MODE="$1" AGENT_CAGE_BIN="$2" REPO="$HERE" HERMES_BIN="$W/bin/hermes" WATCHDOG_HOME="$W/wd" \
  LOG_DIR="$W/log" STATE_DIR="$W/state" NOTIFY="$W/bin/notify.sh" RUN_TIMEOUT=2 \
  bash "$HERE/templates/run-prompt.sh" hourly-quick-repair >/dev/null 2>&1; echo $?
}

# 1. With the cage: the one-shot runs inside it, limit = its own timeout + 60s.
: > "$CAGE_LOG"
[ "$(selftest ok "$W/bin/agent-cage")" = "0" ] && ok "1 selftest through the cage still reports a healthy healer" || bad "1 caged selftest failed"
grep -qx -- "--max 62s -- timeout 2 $W/bin/hermes -z reply with the single word: ok" "$CAGE_LOG" \
  && ok "2 the probe ran inside agent-cage, limited to PROBE_TIMEOUT plus a minute" || bad "2 the probe was not caged" "$(cat "$CAGE_LOG")"

: > "$CAGE_LOG"
[ "$(runprompt ok "$W/bin/agent-cage")" = "0" ] && ok "3 run-prompt through the cage still reports a good run" || bad "3 caged run-prompt failed"
grep -q -- "^--max 62s -- timeout 2 $W/bin/hermes -z" "$CAGE_LOG" \
  && ok "4 the operator run went through agent-cage, limited to RUN_TIMEOUT plus a minute" || bad "4 the operator run was not caged" "$(head -c 300 "$CAGE_LOG")"

# 5. The inner timeout still fires first and its exit code still comes back, so a
#    slow run is still told apart from a dead one.
: > "$NOTIFY_LOG"
t0=$(date +%s); rc="$(runprompt slow "$W/bin/agent-cage")"; t1=$(date +%s)
[ $((t1 - t0)) -lt 20 ] && ok "5 a caged run that outlives its cap is stopped (after $((t1 - t0))s)" || bad "5 caged slow run was not stopped" "$((t1 - t0))s"
[ "$rc" = "21" ] && grep -q "stopped at its 2s limit while it was still working" "$NOTIFY_LOG" \
  && ok "6 and is still reported as a slow run, not a dead one (rc=$rc)" || bad "6 the timeout's exit code was lost" "rc=$rc $(cat "$NOTIFY_LOG")"

# 7. Without the cage everything works as before, and nothing tries to run it.
: > "$CAGE_LOG"
[ "$(selftest ok "")" = "0" ] && ok "7 cage switched off (AGENT_CAGE_BIN empty): selftest works" || bad "7 selftest broke without the cage"
[ "$(selftest ok "$W/no-such-agent-cage")" = "0" ] && ok "8 cage not installed: selftest works" || bad "8 selftest broke when the cage is missing"
[ "$(runprompt ok "$W/no-such-agent-cage")" = "0" ] && ok "9 cage not installed: run-prompt works" || bad "9 run-prompt broke when the cage is missing"
[ ! -s "$CAGE_LOG" ] && ok "10 and the cage was never called" || bad "10 the cage was called anyway" "$(cat "$CAGE_LOG")"

# 11. The cron example cages every agent job and leaves the floor alone.
CRON="$HERE/templates/cron.example"
agent_jobs="$(grep -cE '^[#]? *[0-9*@].*(selftest|run-prompt)\.sh' "$CRON")"
caged_jobs="$(grep -cE '^[#]? *[0-9*@].*/usr/local/bin/agent-cage --max [0-9]+[smh] -- .*(selftest|run-prompt)\.sh' "$CRON")"
[ "$agent_jobs" -ge 3 ] && [ "$agent_jobs" = "$caged_jobs" ] && ok "11 every agent job in cron.example runs through agent-cage ($caged_jobs of $agent_jobs)" || bad "11 an agent job in cron.example is not caged" "$caged_jobs of $agent_jobs"
grep -E '^[0-9*].*quick-check\.sh' "$CRON" | grep -vq agent-cage && ok "12 the floor stays outside the cage" || bad "12 the floor was caged"
grep -q 'kit-bootstrap' "$CRON" && ok "13 cron.example says where agent-cage comes from" || bad "13 no pointer to kit-bootstrap"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
