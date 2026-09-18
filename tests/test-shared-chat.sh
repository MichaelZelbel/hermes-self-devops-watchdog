#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/profile"
printf '{"enabled":true}\n' > "$TEST_DIR/profile/hub-chat.json"
cat > "$TEST_DIR/chat" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$CHAT_TEST_CALLS"
printf '{"state":"queued"}\n'
SCRIPT
chmod +x "$TEST_DIR/chat"
export CHAT_TEST_CALLS="$TEST_DIR/calls" HUB_CHAT_PROFILE="$TEST_DIR/profile" HUB_CHAT_COMMAND="$TEST_DIR/chat"
export LOG_FILE="$TEST_DIR/notify.log" STATE_DIR="$TEST_DIR/state" NOTIFY_SENDER=hermes-send HERMES_BIN="$TEST_DIR/no-hermes"
NOTIFY_STATUS='repaired automatically' bash "$ROOT/templates/notify.sh" 'A repair finished'
test ! -e "$CHAT_TEST_CALLS"
NOTIFY_STATUS='still down, needs you' bash "$ROOT/templates/notify.sh" 'A service failed'
grep -q 'submit-critical watchdog:gateway' "$CHAT_TEST_CALLS"
grep -q 'delivery is not yet confirmed' "$LOG_FILE"
if grep -q 'sent to' "$LOG_FILE"; then exit 1; fi
printf 'shared conversation routing: passed\n'
