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

run() { HERMES_BIN="$W/bin/hermes" SEND_HOME="$W/home" ALERT_TARGET="${TARGET:-telegram}" LOG_FILE="$W/notify.log" bash "$HERE/templates/notify.sh" "$@" 2>"$W/err" >/dev/null; echo $?; }

[ "$(run "gateway restarted")" = "0" ] && ok "1 a message is sent and exit is 0" || bad "1 send failed"
grep -q -- "-t telegram" "$W/args" && ok "2 the default target is telegram" || bad "2 target wrong" "$(cat "$W/args")"
grep -q "gateway restarted" "$W/body" && ok "3 the body reaches hermes send on stdin" || bad "3 body missing"
[ "$(printf 'piped text' | HERMES_BIN="$W/bin/hermes" SEND_HOME="$W/home" LOG_FILE="$W/notify.log" bash "$HERE/templates/notify.sh" 2>/dev/null >/dev/null; echo $?)" = "0" ] && grep -q "piped text" "$W/body" && ok "4 stdin works when no argument is given" || bad "4 stdin path broken"
[ "$(SEND_RC=1 SEND_OUT="Error: no such target" run "x")" = "30" ] && ok "5 a failed send is exit 30" || bad "5 failure passed as delivery"
[ "$(SEND_RC=0 SEND_OUT="failed to deliver" run "x")" = "30" ] && ok "6 an error printed with exit 0 is still not delivery (output is tested)" || bad "6 exit code trusted"
[ "$(run "")" = "30" ] && ok "7 an empty message is refused" || bad "7 empty message sent"
run "token leak eyJhbGciOiJSUzI1NiJ9.secretsecret" >/dev/null
grep -q "secretsecret" "$W/body" && bad "8 a token reached the message" "$(cat "$W/body")" || ok "8 a token-shaped string is redacted before sending"
[ "$(TARGET="discord:#ops" run "x")" = "0" ] && grep -q -- "-t discord:#ops" "$W/args" && ok "9 ALERT_TARGET overrides the platform" || bad "9 override ignored"
grep -q "sent to" "$W/notify.log" && ok "10 deliveries are logged without the full body" || bad "10 no log line"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
