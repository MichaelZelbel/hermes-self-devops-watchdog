#!/usr/bin/env bash
# ==============================================================================
# Fetch the shared deterministic floor from its ONE upstream, at a pinned
# commit, and refuse it unless its hash matches.
#
# The floor (quick-check.sh: is the gateway alive? restart once if not) is
# operator-agnostic and is maintained in one place, the
# hermes-claude-code-devops-watchdog repository. This project consumes it and
# never edits it. Two copies would drift; kit-bootstrap exists because four
# installers once drifted until 212 of 309 lines differed.
#
# floor/PIN holds two lines:  COMMIT=<40-hex>   SHA256=<64-hex>
# Move the pin by editing that file after reading the upstream diff, and by
# running tests/test-floor-pin.sh, which fetches and verifies.
#
# Usage: floor/fetch-floor.sh [dest]     (default dest: floor/quick-check.sh)
# Exit: 0 fetched and verified; 1 mismatch or fetch failure (nothing written).
# ==============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$HERE/quick-check.sh}"
PIN="$HERE/PIN"
UPSTREAM_REPO="${UPSTREAM_REPO:-MichaelZelbel/hermes-claude-code-devops-watchdog}"
UPSTREAM_PATH="${UPSTREAM_PATH:-templates/quick-check.sh}"

[ -f "$PIN" ] || { echo "fetch-floor: no PIN file at $PIN" >&2; exit 1; }
COMMIT="$(sed -n 's/^COMMIT=//p' "$PIN" | tr -d '[:space:]')"
SHA256="$(sed -n 's/^SHA256=//p' "$PIN" | tr -d '[:space:]')"
printf '%s' "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || { echo "fetch-floor: PIN has no 40-hex COMMIT (a branch name moves; pin a commit)" >&2; exit 1; }
printf '%s' "$SHA256" | grep -qE '^[0-9a-f]{64}$' || { echo "fetch-floor: PIN has no 64-hex SHA256" >&2; exit 1; }

# A local mirror lets the tests run with no network: FLOOR_SOURCE=file:///path
URL="${FLOOR_SOURCE:-https://raw.githubusercontent.com/$UPSTREAM_REPO/$COMMIT/$UPSTREAM_PATH}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL "$URL" -o "$tmp"; then
  echo "fetch-floor: could not fetch $URL" >&2; exit 1
fi
got="$(sha256sum "$tmp" | cut -c1-64)"
if [ "$got" != "$SHA256" ]; then
  echo "fetch-floor: hash mismatch for $URL" >&2
  echo "  pinned: $SHA256" >&2
  echo "  got:    $got" >&2
  echo "  Nothing was written. Read the upstream diff, then move the pin on purpose." >&2
  exit 1
fi
install -m 0755 "$tmp" "$DEST" && chmod +x "$DEST"   # chmod again: install's mode is not honoured on every filesystem
echo "floor: $UPSTREAM_PATH at $COMMIT verified and written to $DEST"
