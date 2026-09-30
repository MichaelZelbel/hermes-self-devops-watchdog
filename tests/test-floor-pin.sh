#!/usr/bin/env bash
# The floor (quick-check.sh and stale-check.sh) is fetched from one upstream at
# a pinned commit and refused unless both hashes match. Offline cases use a
# file:// mirror; the real fetch runs only when the network answers, and says
# so when it does not.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# A stand-in for the fetch script's directory, so PIN can be varied.
mkdir -p "$W/floor"; cp "$HERE/floor/fetch-floor.sh" "$W/floor/"
# A mirror laid out like the upstream repository: <base>/templates/<name>.
mkdir -p "$W/mirror/templates"
printf '#!/bin/sh\nnot the floor\n' > "$W/mirror/templates/quick-check.sh"
printf '#!/bin/sh\nnot the stale check\n' > "$W/mirror/templates/stale-check.sh"
hq="$(sha256sum "$W/mirror/templates/quick-check.sh" | cut -c1-64)"
hs="$(sha256sum "$W/mirror/templates/stale-check.sh" | cut -c1-64)"
# A file:// URL curl can open on this platform: Windows curl wants C:/... paths.
mirror="$W/mirror"; command -v cygpath >/dev/null 2>&1 && mirror="/$(cygpath -m "$mirror")"
BASE_URL="file://$mirror"
A40="$(printf 'a%.0s' $(seq 40))"

# 1. Hash mismatch: refused, nothing written.
printf 'COMMIT=%s\nSHA256=%s\nSTALE_SHA256=%s\n' "$A40" "$(printf 'b%.0s' $(seq 64))" "$hs" > "$W/floor/PIN"
FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/out.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$W/out.sh" ] && grep -q "hash mismatch" "$W/err" && ok "1 a hash mismatch is refused and nothing is written" || bad "1 mismatch accepted" "rc=$rc $(cat "$W/err")"

# 2. Matching hash: written, executable.
printf 'COMMIT=%s\nSHA256=%s\nSTALE_SHA256=%s\n' "$A40" "$hq" "$hs" > "$W/floor/PIN"
FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/out.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && [ -x "$W/out.sh" ] && ok "2 a matching hash is written and executable" || bad "2 good fetch failed" "rc=$rc $(cat "$W/err")"

# 3. A malformed PIN is refused before any fetch.
printf 'COMMIT=main\nSHA256=%s\nSTALE_SHA256=%s\n' "$hq" "$hs" > "$W/floor/PIN"
FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/out2.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && grep -q "40-hex COMMIT" "$W/err" && ok "3 a pin that is a branch name, not a commit, is refused (branches move)" || bad "3 branch pin accepted"

# 4. The repository's own PIN is well-formed.
grep -qE '^COMMIT=[0-9a-f]{40}$' "$HERE/floor/PIN" && grep -qE '^SHA256=[0-9a-f]{64}$' "$HERE/floor/PIN" \
  && grep -qE '^STALE_SHA256=[0-9a-f]{64}$' "$HERE/floor/PIN" \
  && ok "4 floor/PIN carries a 40-hex commit and two 64-hex hashes" || bad "4 PIN malformed" "$(cat "$HERE/floor/PIN")"

# 5. The real upstream, when reachable.
if curl -fsSI --max-time 8 https://raw.githubusercontent.com >/dev/null 2>&1; then
  bash "$HERE/floor/fetch-floor.sh" "$W/real.sh" >/dev/null 2>"$W/err"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "hermes-gateway.service" "$W/real.sh" && grep -q "unit_is_stale" "$W/stale-check.sh" \
    && ok "5 the pinned upstream floor fetches and verifies, both files" || bad "5 real fetch failed" "rc=$rc $(cat "$W/err")"
  grep -q "state established" "$W/real.sh" && ok "6 and it is the order-independent :443 probe, not the older one" || bad "6 the pinned floor is the old probe"
else
  printf '  skip 5 no network, the real fetch was not tried\n'
fi

# 7. The floor is never committed here.
tracked=""
for f in floor/quick-check.sh floor/stale-check.sh; do
  git -C "$HERE" ls-files --error-unmatch "$f" >/dev/null 2>&1 && tracked="$tracked $f"
done
[ -z "$tracked" ] && ok "7 floor/quick-check.sh and floor/stale-check.sh are not tracked (fetched, not copied)" || bad "7 tracked:$tracked; they must be fetched, not copied"

# 8. quick-check matches but stale-check does not: refused, and NEITHER file is written.
printf 'COMMIT=%s\nSHA256=%s\nSTALE_SHA256=%s\n' "$A40" "$hq" "$(printf 'c%.0s' $(seq 64))" > "$W/floor/PIN"
FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/o8/quick-check.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$W/o8/quick-check.sh" ] && [ ! -e "$W/o8/stale-check.sh" ] \
  && grep -q "hash mismatch for templates/stale-check.sh" "$W/err" && ok "8 one bad hash refuses both files" || bad "8 partial write" "rc=$rc $(cat "$W/err")"

# 9. Both match: both written next to each other, executable.
printf 'COMMIT=%s\nSHA256=%s\nSTALE_SHA256=%s\n' "$A40" "$hq" "$hs" > "$W/floor/PIN"
mkdir -p "$W/o9"; FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/o9/quick-check.sh" >/dev/null 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && [ -x "$W/o9/quick-check.sh" ] && [ -x "$W/o9/stale-check.sh" ] && ok "9 both hashes match: both files written and executable" || bad "9 good pair failed" "rc=$rc $(cat "$W/err")"

# 10. Both verify but the destination cannot be written: a failure, never "verified and written".
printf 'COMMIT=%s\nSHA256=%s\nSTALE_SHA256=%s\n' "$A40" "$hq" "$hs" > "$W/floor/PIN"
: > "$W/not-a-dir"
FLOOR_BASE="$BASE_URL" bash "$W/floor/fetch-floor.sh" "$W/not-a-dir/quick-check.sh" >"$W/out10" 2>"$W/err"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "verified and written" "$W/out10" && ok "10 a destination that cannot be written is a failure, not a success" || bad "10 failed write reported as success" "rc=$rc $(cat "$W/out10")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
