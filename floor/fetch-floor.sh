#!/usr/bin/env bash
# ==============================================================================
# Fetch the shared deterministic floor from its ONE upstream, at a pinned
# commit, and refuse it unless every hash matches.
#
# The floor is two files, maintained in one place, the
# hermes-claude-code-devops-watchdog repository:
#   quick-check.sh  is the gateway alive? restart once if not.
#   stale-check.sh  is it running older code or settings than are on disk?
#                   restart once if so. A separate script because it answers a
#                   different question, with its own cron line, state and lock.
# This project consumes them and never edits them. Two copies would drift;
# kit-bootstrap exists because four installers once drifted until 212 of 309
# lines differed.
#
# floor/PIN holds three lines:  COMMIT=<40-hex>  SHA256=<64-hex>  STALE_SHA256=<64-hex>
# (SHA256 is quick-check.sh's, STALE_SHA256 is stale-check.sh's, both at COMMIT.)
# Move the pin by editing that file after reading the upstream diff, and by
# running tests/test-floor-pin.sh, which fetches and verifies.
#
# Usage: floor/fetch-floor.sh [dest]     (default dest: floor/quick-check.sh)
# stale-check.sh is written next to dest. Both are verified before either is
# written, so a bad hash on one leaves neither.
# Exit: 0 fetched and verified; 1 mismatch or fetch failure (nothing written).
# ==============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$HERE/quick-check.sh}"
PIN="$HERE/PIN"
UPSTREAM_REPO="${UPSTREAM_REPO:-MichaelZelbel/hermes-claude-code-devops-watchdog}"

[ -f "$PIN" ] || { echo "fetch-floor: no PIN file at $PIN" >&2; exit 1; }
COMMIT="$(sed -n 's/^COMMIT=//p' "$PIN" | tr -d '[:space:]')"
SHA256="$(sed -n 's/^SHA256=//p' "$PIN" | tr -d '[:space:]')"
STALE_SHA256="$(sed -n 's/^STALE_SHA256=//p' "$PIN" | tr -d '[:space:]')"
printf '%s' "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || { echo "fetch-floor: PIN has no 40-hex COMMIT (a branch name moves; pin a commit)" >&2; exit 1; }
printf '%s' "$SHA256" | grep -qE '^[0-9a-f]{64}$' || { echo "fetch-floor: PIN has no 64-hex SHA256" >&2; exit 1; }
printf '%s' "$STALE_SHA256" | grep -qE '^[0-9a-f]{64}$' || { echo "fetch-floor: PIN has no 64-hex STALE_SHA256" >&2; exit 1; }

# A local mirror lets the tests run with no network: FLOOR_BASE=file:///path,
# holding templates/quick-check.sh and templates/stale-check.sh.
BASE="${FLOOR_BASE:-https://raw.githubusercontent.com/$UPSTREAM_REPO/$COMMIT}"
DEST_DIR="$(dirname "$DEST")"
tq="$(mktemp)"; tsx="$(mktemp)"; trap 'rm -f "$tq" "$tsx"' EXIT
fetch_verify() { # fetch_verify <path-in-repo> <sha256> <tmpfile>
  curl -fsSL "$BASE/$1" -o "$3" || { echo "fetch-floor: could not fetch $BASE/$1" >&2; return 1; }
  local got; got="$(sha256sum "$3" | cut -c1-64)"
  [ "$got" = "$2" ] || { printf 'fetch-floor: hash mismatch for %s\n  pinned: %s\n  got:    %s\n  Nothing was written. Read the upstream diff, then move the pin on purpose.\n' "$1" "$2" "$got" >&2; return 1; }
}
fetch_verify templates/quick-check.sh "$SHA256" "$tq" || exit 1
fetch_verify templates/stale-check.sh "$STALE_SHA256" "$tsx" || exit 1
mkdir -p "$DEST_DIR"
# chmod again after install: install's mode is not honoured on every filesystem
install -m 0755 "$tq" "$DEST" && chmod +x "$DEST"
install -m 0755 "$tsx" "$DEST_DIR/stale-check.sh" && chmod +x "$DEST_DIR/stale-check.sh"
echo "floor: quick-check.sh and stale-check.sh at $COMMIT verified and written to $DEST_DIR"
