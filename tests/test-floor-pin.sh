#!/usr/bin/env bash
# The floor is fetched from one upstream at a pinned commit and refused unless
# its hash matches. Offline cases use a file:// source; the real fetch runs
# only when the network answers, and says so when it does not.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# A stand-in for the fetch script's directory, so PIN can be varied.
mkdir -p "$W/floor"; cp "$HERE/floor/fetch-floor.sh" "$W/floor/"
printf '#!/bin/sh\nnot the floor\n' > "$W/fake.sh"
# A file:// URL curl can open on this platform: Windows curl wants C:/... paths.
src="$W/fake.sh"; command -v cygpath >/dev/null 2>&1 && src="/$(cygpath -m "$src")"
FAKE_URL="file://$src"

# 1. Hash mismatch: refused, nothing written.
printf 'COMMIT=%s\nSHA256=%s\n' "$(printf 'a%.0s' $(seq 40))" "$(printf 'b%.0s' $(seq 64))" > "$W/floor/PIN"
FLOOR_SOURCE="$FAKE_URL" bash "$W/floor/fetch-floor.sh" "$W/out.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$W/out.sh" ] && grep -q "hash mismatch" "$W/err" && ok "1 a hash mismatch is refused and nothing is written" || bad "1 mismatch accepted" "rc=$rc $(cat "$W/err")"

# 2. Matching hash: written, executable.
h="$(sha256sum "$W/fake.sh" | cut -c1-64)"
printf 'COMMIT=%s\nSHA256=%s\n' "$(printf 'a%.0s' $(seq 40))" "$h" > "$W/floor/PIN"
FLOOR_SOURCE="$FAKE_URL" bash "$W/floor/fetch-floor.sh" "$W/out.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && [ -x "$W/out.sh" ] && ok "2 a matching hash is written and executable" || bad "2 good fetch failed" "rc=$rc $(cat "$W/err")"

# 3. A malformed PIN is refused before any fetch.
printf 'COMMIT=main\nSHA256=%s\n' "$h" > "$W/floor/PIN"
FLOOR_SOURCE="$FAKE_URL" bash "$W/floor/fetch-floor.sh" "$W/out2.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && grep -q "40-hex COMMIT" "$W/err" && ok "3 a pin that is a branch name, not a commit, is refused (branches move)" || bad "3 branch pin accepted"

# 4. The repository's own PIN is well-formed.
grep -qE '^COMMIT=[0-9a-f]{40}$' "$HERE/floor/PIN" && grep -qE '^SHA256=[0-9a-f]{64}$' "$HERE/floor/PIN" && ok "4 floor/PIN carries a 40-hex commit and a 64-hex hash" || bad "4 PIN malformed" "$(cat "$HERE/floor/PIN")"

# 5. The real upstream, when reachable.
if curl -fsSI --max-time 8 https://raw.githubusercontent.com >/dev/null 2>&1; then
  bash "$HERE/floor/fetch-floor.sh" "$W/real.sh" >/dev/null 2>"$W/err"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "hermes-gateway.service" "$W/real.sh" && ok "5 the pinned upstream floor fetches and verifies" || bad "5 real fetch failed" "rc=$rc $(cat "$W/err")"
  grep -q "state established" "$W/real.sh" && ok "6 and it is the order-independent :443 probe, not the older one" || bad "6 the pinned floor is the old probe"
else
  printf '  skip 5 no network, the real fetch was not tried\n'
fi

# 7. The floor is never committed here.
git -C "$HERE" ls-files --error-unmatch floor/quick-check.sh >/dev/null 2>&1 && bad "7 floor/quick-check.sh is tracked; it must be fetched, not copied" || ok "7 floor/quick-check.sh is not tracked (fetched, not copied)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
