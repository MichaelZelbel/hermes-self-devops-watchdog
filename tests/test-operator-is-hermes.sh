#!/usr/bin/env bash
# The operator layer names Hermes, not the sister project's tool. The sister
# project may be NAMED where the two are compared (README, architecture, the
# floor's provenance); nowhere else.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

allowed='README.md|docs/architecture.md|floor/FLOOR.md|floor/fetch-floor.sh|floor/PIN|tests/test-operator-is-hermes.sh|tests/test-floor-pin.sh'
leaks="$(cd "$HERE" && git ls-files | grep -vE "^($allowed)$" | xargs grep -il 'claude' 2>/dev/null)"
[ -z "$leaks" ] && ok "1 no operator file names the other tool" || bad "1 the other tool is named outside the comparison" "$leaks"

for f in prompts/hourly-quick-repair.md prompts/six-hour-deep-check.md prompts/update-maintenance.md hermes-devops-runbook.md AGENT_START.md; do
  grep -q "watchdog" "$HERE/$f" && grep -qi "hermes" "$HERE/$f" && ok "2 $f addresses the watchdog Hermes" || bad "2 $f does not name the watchdog profile"
done

[ ! -e "$HERE/CLAUDE.md" ] && [ -f "$HERE/AGENTS.md" ] && ok "3 the rules file is AGENTS.md, which Hermes reads by name" || bad "3 rules file wrong"
ls "$HERE"/templates/claude-settings.* >/dev/null 2>&1 && bad "4 the other tool's settings templates are still here" || ok "4 no settings templates of the other tool"
[ -f "$HERE/templates/hermes-approvals.conservative.example.yaml" ] && [ -f "$HERE/templates/hermes-approvals.autonomous-devops.example.yaml" ] && ok "5 both approvals templates present" || bad "5 approvals templates missing"

# The conservative template refuses the operator's restart; the autonomous one does not.
grep -q '"\*hermes gateway restart\*"' "$HERE/templates/hermes-approvals.conservative.example.yaml" && ok "6 conservative refuses the operator's restart (the floor restarts)" || bad "6 conservative lets the operator restart"
grep -q '"\*hermes gateway restart\*"' "$HERE/templates/hermes-approvals.autonomous-devops.example.yaml" && bad "7 autonomous still refuses the restart" || ok "7 autonomous allows the one restart"
for pat in '"\*hermes update\*"' '"\*hermes auth\*"' '"\*hermes config set\*"' '"\*ufw \*"' '"\*rm -rf\*"'; do
  grep -q "$pat" "$HERE/templates/hermes-approvals.autonomous-devops.example.yaml" && ok "8 autonomous still refuses $pat" || bad "8 autonomous dropped $pat"
done

# Nothing in the repo schedules the floor or the self-check on hermes cron.
grep -rn "hermes cron create" "$HERE/templates/cron.example" "$HERE/templates/selftest.sh" "$HERE/floor/fetch-floor.sh" >/dev/null 2>&1 && bad "9 the floor or self-check is on hermes cron" || ok "9 the floor and the self-check live on the machine's cron"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
