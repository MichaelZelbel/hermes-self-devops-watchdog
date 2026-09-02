# The leash on the watchdog profile

Hermes decides, per command, whether to run it, ask, or refuse. In a scheduled run there is nobody to
ask, so the question is which commands are refused outright. That list lives in the watchdog profile's
own config, not the gateway's, and it is the leash on the operator.

## Two templates

- `templates/hermes-approvals.conservative.example.yaml`: read-only operator. It may look, report
  and ask; the floor does the restarts. Start here.
- `templates/hermes-approvals.autonomous-devops.example.yaml`: after you trust the flow, the operator
  may also restart a managed gateway once and vacuum the journal under critical disk pressure. Everything
  security-sensitive stays refused.

Both are lists of patterns for `approvals.deny`, and the difference between them is two lines.

## Applying one

The list goes into the watchdog profile through `hermes config set`, as a JSON list, with the
profile's home selected:

```bash
export HERMES_HOME="$HOME/.hermes/profiles/watchdog"
hermes config set approvals.deny '["*rm -rf*", "*shred *", ...]'
hermes config get approvals.deny
hermes approvals test "hermes update"
```

Two checks that matter, because both bit for real:

1. **Read it back.** An older Hermes stored a JSON list as one plain string, which its readers ignore,
   so the setting landed and did nothing. `hermes config get approvals.deny` must print one `- ` entry
   per line. A single quoted blob is a leash that is not on.
2. **Test it.** `hermes approvals test "<command>"` prints the verdict without running anything: exit
   3 is refused, 2 is ask, 0 is allow. Test one command that must be refused and one that must not
   (`git status`), because a list that refuses everything passes a one-sided check.

Unattended runs default to refusing rather than queueing a dangerous command; that is the shipped
behaviour and these templates leave it alone.

## What `command_allowlist` is for

`hermes approvals suggest` mines past approval decisions and proposes `command_allowlist` entries so
commands you keep approving stop prompting. On the watchdog profile there are no prompts to answer, so
the allowlist is how you say "this exact command is fine" (for example the restart command) without
weakening the deny list. Add entries by hand after reading them.

## Never work around a refusal

If the operator's run is refused a command, the correct result is a line in the report under "Needs
the operator". The operator layer must not rephrase the command, wrap it in a script, or ask the floor
to do it. The tests in `tests/` check the templates refuse what they say they refuse; the runbook says
the same in words.
