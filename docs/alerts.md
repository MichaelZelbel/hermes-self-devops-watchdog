# Alerts

## Policy

Quiet when healthy. Speak for a repair, an incident, an approval request, or the self-check failing.
No message for a routine healthy run. An optional daily summary if the operator asks for one.

## The channel

`hermes send -t <target>`, wrapped by `templates/notify.sh`. It reuses the platform credentials the
gateway already holds, so:

- no bot token is copied into a second file,
- no chat id is looked up by hand (`hermes send --list` shows what Hermes knows),
- no message splitter is maintained,
- no model is involved, so an alert about the model being down can still be delivered.

The target defaults to `telegram` (the platform's home channel). `ALERT_TARGET=discord:#ops` or
`telegram:<chat_id>` overrides it, in the cron environment.

## What every alert carries

1. The self-check result first. Either "healer answered" or **SELF-HEALING IS DOWN** with the reason
   and where the fix lands.
2. What was checked, what changed, current status, what needs the operator, in the runbook's format.
3. No secrets. `notify.sh` and `selftest.sh` redact token-shaped strings before anything is sent or
   logged, and the runbook forbids printing them in the first place.

## Rate limiting

The self-check alerts once when the healer goes down and then once every six hours while it stays
down (`ALERT_EVERY`), and once when it recovers. The floor sends nothing itself; its restarts are
findings for the hourly operator run to explain.

## When delivery itself fails

`notify.sh` exits 30 and writes the reason to `/var/log/hermes-watchdog/notify.log`. The deep check
reads that log; a notifier that cannot deliver is an incident in its own right, because it is the
difference between a quiet night and a silent one.
