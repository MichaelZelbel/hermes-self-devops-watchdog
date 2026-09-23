#!/usr/bin/env bash
# notify.sh through a stub `hermes send`: delivery, failure, empty, redaction.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

cat > "$W/bin/hermes" <<'EOF'
#!/usr/bin/env bash
# records argv and stdin; SEND_RC decides the exit; SEND_OUT the printed text
printf '%s\n' "$*" > "$STUB_ARGS"
cat > "$STUB_BODY"
printf '%s\n' "${SEND_OUT:-sent}"
exit "${SEND_RC:-0}"
EOF
chmod +x "$W/bin/hermes"
export STUB_ARGS="$W/args" STUB_BODY="$W/body"

# GODSPEED_NOTIFY points at nothing on purpose: on a mission control host the real /usr/local/bin/mc-notify
# exists, "auto" would pick it, and cases 1-10 would test that host instead of this script.
# NOTIFY_DEDUP_SECONDS=0: several cases send the same one-letter message, and since the
# alert policy of v1.0.10 a repeat inside the window is deliberately not sent again.
run() { GODSPEED_NOTIFY="$W/no-godspeed-notify-here" STATE_DIR="$W/state" NOTIFY_DEDUP_SECONDS=0 HERMES_BIN="$W/bin/hermes" SEND_HOME="$W/home" ALERT_TARGET="${TARGET:-telegram}" LOG_FILE="$W/notify.log" bash "$HERE/templates/notify.sh" "$@" 2>"$W/err" >/dev/null; echo $?; }

[ "$(run "gateway restarted")" = "0" ] && ok "1 a message is sent and exit is 0" || bad "1 send failed"
grep -q -- "-t telegram" "$W/args" && ok "2 the default target is telegram" || bad "2 target wrong" "$(cat "$W/args")"
grep -q "gateway restarted" "$W/body" && ok "3 the body reaches hermes send on stdin" || bad "3 body missing"
[ "$(printf 'piped text' | GODSPEED_NOTIFY="$W/no-godspeed-notify-here" STATE_DIR="$W/state" HERMES_BIN="$W/bin/hermes" SEND_HOME="$W/home" LOG_FILE="$W/notify.log" bash "$HERE/templates/notify.sh" 2>/dev/null >/dev/null; echo $?)" = "0" ] && grep -q "piped text" "$W/body" && ok "4 stdin works when no argument is given" || bad "4 stdin path broken"
[ "$(SEND_RC=1 SEND_OUT="Error: no such target" run "x")" = "30" ] && ok "5 a failed send is exit 30" || bad "5 failure passed as delivery"
[ "$(SEND_RC=0 SEND_OUT="failed to deliver" run "x")" = "30" ] && ok "6 an error printed with exit 0 is still not delivery (output is tested)" || bad "6 exit code trusted"
[ "$(run "")" = "30" ] && ok "7 an empty message is refused" || bad "7 empty message sent"
run "token leak eyJhbGciOiJSUzI1NiJ9.secretsecret" >/dev/null
grep -q "secretsecret" "$W/body" && bad "8 a token reached the message" "$(cat "$W/body")" || ok "8 a token-shaped string is redacted before sending"
[ "$(TARGET="discord:#ops" run "x")" = "0" ] && grep -q -- "-t discord:#ops" "$W/args" && ok "9 ALERT_TARGET overrides the platform" || bad "9 override ignored"
grep -q "sent to" "$W/notify.log" && ok "10 deliveries are logged without the full body" || bad "10 no log line"

# --- the way across to mc-notify (2026-09-17) --------------------------------
# Until this date notify.sh hopped through `sudo -n` unconditionally, under a comment
# claiming the kit installs the rule. No kit ever did. Now the hop happens only where a
# rule already exists, or where the host says so; and a failure carries its own words.
cat > "$W/bin/mc-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HN_ARGS"
[ -n "${HN_ERR:-}" ] && { echo "$HN_ERR" >&2; exit 1; }
exit 0
EOF
cat > "$W/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# a stub: `-n -l <cmd>` answers SUDO_RULE_RC (0 = a rule exists); anything else runs it
printf 'sudo %s\n' "$*" >> "$SUDO_LOG"
if [ "${1:-}" = "-n" ] && [ "${2:-}" = "-l" ]; then exit "${SUDO_RULE_RC:-1}"; fi
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
chmod +x "$W/bin/mc-notify" "$W/bin/sudo"
export HN_ARGS="$W/hn-args" SUDO_LOG="$W/sudo.log"
godspeed() { : > "$SUDO_LOG"; rm -f "$HN_ARGS"; PATH="$W/bin:$PATH" NOTIFY_SENDER=mc-notify GODSPEED_NOTIFY="$W/bin/mc-notify" LOG_FILE="$W/notify.log" STATE_DIR="$W/state" bash "$HERE/templates/notify.sh" "$@" 2>"$W/err" >/dev/null; echo $?; }
ran_through_sudo() { grep -q "^sudo -n $W/bin/mc-notify" "$SUDO_LOG"; }

if [ "$(id -u)" -eq 0 ]; then
  ok "11-16 skipped: root needs no way across, so there is nothing to choose (run as the service user)"
else
  [ "$(SUDO_RULE_RC=1 mission control "needs a look")" = "0" ] && [ -f "$HN_ARGS" ] && ! ran_through_sudo \
    && ok "11 no rule for this binary: mc-notify is called directly, nothing hops" || bad "11 hopped through sudo without a rule" "$(cat "$SUDO_LOG")"
  [ "$(SUDO_RULE_RC=0 mission control "needs a look")" = "0" ] && ran_through_sudo \
    && ok "12 a rule that already exists is used" || bad "12 an existing rule was ignored" "$(cat "$SUDO_LOG")"
  [ "$(SUDO_RULE_RC=0 NOTIFY_SUDO="" godspeed "needs a look")" = "0" ] && [ -f "$HN_ARGS" ] && [ ! -s "$SUDO_LOG" ] \
    && ok "13 NOTIFY_SUDO=\"\" never hops and never even asks sudo" || bad "13 sudo was touched although the host said never" "$(cat "$SUDO_LOG")"
  [ "$(SUDO_RULE_RC=1 NOTIFY_SUDO="sudo -n" godspeed "needs a look")" = "0" ] && ran_through_sudo && ! grep -q -- "-n -l" "$SUDO_LOG" \
    && ok "14 NOTIFY_SUDO=\"sudo -n\" always hops, without probing" || bad "14 the explicit hop was not taken" "$(cat "$SUDO_LOG")"
  grep -q -- "--lane card" "$HN_ARGS" && ok "15 the card lane still reaches mc-notify with its arguments" || bad "15 arguments lost" "$(cat "$HN_ARGS" 2>/dev/null)"
  NOTIFY_STATUS="repaired automatically" HN_ERR="mc-notify: cannot read /etc/godspeed/secret: Permission denied" SUDO_RULE_RC=1 mission control "restarted it" >/dev/null
  grep -q "Permission denied" "$W/notify.log" \
    && ok "16 when the ledger is not reached, the log carries mc-notify's own words" || bad "16 the cause was swallowed" "$(tail -2 "$W/notify.log")"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
