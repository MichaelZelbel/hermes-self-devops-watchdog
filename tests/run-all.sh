#!/usr/bin/env bash
# Every test, no network needed except the one real floor fetch, which skips
# itself when the network is away. Bash only. Safe on any machine.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in test-floor-pin.sh test-selftest.sh test-notify.sh test-run-prompt.sh test-operator-is-hermes.sh; do
  echo "== $t"
  bash "$HERE/$t" || rc=1
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  shellcheck "$HERE"/../templates/*.sh "$HERE"/../floor/fetch-floor.sh "$HERE"/*.sh && echo "  ok   shellcheck clean" || rc=1
else
  echo "  skip shellcheck not installed"
fi
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOMETHING FAILED"
exit "$rc"
