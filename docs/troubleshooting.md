# Troubleshooting

## The alert says SELF-HEALING IS DOWN

The watchdog Hermes could not answer one word. Read the reason in the alert; it is the model's own
error line. The usual causes, in order of how often they happen:

1. **The shared sign-in expired.** The watchdog profile uses the same credential store as the
   gateway, so the gateway is probably failing too, quietly. As the gateway user:
   `hermes auth add <provider> --type oauth --no-browser`, type the code on any device, then run
   `templates/selftest.sh` by hand. The alert clears itself on the next probe and sends one
   "repaired" line.
2. **A rate limit.** `HTTP 429: Rate limit reached for this account.` The subscription's ceiling. If
   a fallback chain is configured (`hermes fallback list`), Hermes should have taken it; if the line
   still appears, the chain is empty or the fallback provider is also refusing. Wait, or add a
   fallback (`hermes config set fallback_providers '[{"provider":"openrouter","model":"..."}]'`).
3. **The profile is missing.** `hermes profile create watchdog`, then apply the approvals template.
4. **Hermes itself is missing** (a botched update, a wiped home). Reinstall as the gateway user.

While this alert stands, the floor still restarts a dead gateway, and nothing else repairs itself.

## The gateway is down and the floor keeps restarting it

Look at `/var/log/hermes-watchdog/quick.log` for which probe failed, then `hermes logs errors --since
1h` as the gateway user. Common: the platform token was revoked (the handshake line never appears
after start); the provider sign-in expired (see above); a config edit that the gateway cannot load.
The floor will not loop faster than its schedule, but a gateway that dies at every start needs a
person.

## `hermes gateway status` and systemd disagree

Read the gateway's health from Hermes. A cleanly stopped gateway reads "failed" to `systemctl
is-active`, so systemd cannot tell an operator's stop from a crash. The floor uses the unit state as
its first probe because an inactive unit is definitely not running; it does not use it as its only one.

## The operator's run did nothing, and exited 0

That is expected: `hermes -z` exits 0 whether or not it reached a model. `templates/run-prompt.sh`
reads the output and reports an API failure as SELF-HEALING IS DOWN. If a run produced no report and
no alert, read `/var/log/hermes-watchdog/<prompt>.log`: the full output is there.

## The operator was refused a command

Correct behaviour. Scheduled runs are refused, not asked, and the report says "needs the operator"
with the command. Decide, then either do it by hand or add the exact command to `command_allowlist`
in the watchdog profile (`docs/approvals.md`). Do not loosen the deny list to make a report go away.

## Alerts are not arriving

`templates/notify.sh` uses `hermes send -t <target>`, which reuses the gateway's platform
credentials. Test it by hand: `hermes send -t telegram "test from the watchdog"` as the gateway user.
`hermes send --list` shows the targets Hermes knows. If the platform is not configured,
`hermes setup` as the gateway user, then one gateway restart. `notify.sh` logs every failure to
`/var/log/hermes-watchdog/notify.log` with the reason.

## The watchdog restarted a healthy idle gateway

It should not: the floor uses activity-independent signals only. If it did, read
`/var/log/hermes-watchdog/quick.log` for the probe that failed. If it was probe B (the `:443`
connection), check `ss -tnp state established | grep 443` while the gateway is idle; a platform in
webhook rather than polling mode holds no outbound connection, and the floor's assumptions do not fit
it. That is an upstream matter for the floor (see `floor/FLOOR.md`), not a local edit.

## Gateway restarts end in SIGKILL

`journalctl -u hermes-gateway` shows `State 'stop-sigterm' timed out. Killing.` The gateway is not
honouring SIGTERM within `TimeoutStopSec`. Raise it with a drop-in:

```ini
# /etc/systemd/system/hermes-gateway.service.d/timeout.conf   (system unit)
[Service]
TimeoutStopSec=120
```

then `systemctl daemon-reload`. For a user unit, the same file under
`~/.config/systemd/user/hermes-gateway.service.d/` and `systemctl --user daemon-reload`. A workaround,
not a fix; remove it when upstream Hermes exits cleanly on SIGTERM.

## Two Hermes profiles seem to share memory or sessions

They should not. `hermes profile list` as each user; confirm the watchdog's runs use
`HERMES_HOME=~/.hermes/profiles/watchdog` (the wrappers set it). If the operator's notes appear in the
gateway's memory, a run was started without the profile selected; fix the cron line, not the memory.
