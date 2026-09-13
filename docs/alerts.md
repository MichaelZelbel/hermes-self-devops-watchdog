# Alerts

## Policy

Quiet when healthy. Quiet when it fixed something itself. One item a human sees once when something
should be looked at. A message at once only when the gateway is down and stays down, or when the
self-repair itself is down.

Every message carries a status, set by the caller (`NOTIFY_STATUS`) or derived from its words, and
`templates/notify.sh` sorts it into one of three classes:

| class  | statuses                                                        | what happens                                                                 |
|--------|-----------------------------------------------------------------|------------------------------------------------------------------------------|
| quiet  | recovered on its own, repaired automatically, for the record    | logged; recorded on the hub's ledger where one exists; sent nowhere          |
| card   | needs a person, warning not broken yet, alert                   | on a hub host: one card on the attention ledger, one per topic per day; elsewhere: sent, the same first line at most once per `NOTIFY_DEDUP_SECONDS` (default a day) |
| urgent | still down needs you, self-repair is down needs you             | sent now, every time                                                         |

Why: on the kit's own first host, every self-repaired restart produced a message, the operator
escalated the same recurring fault several times a day, and the human counted a hundred messages in a
day with nothing in them he had to do. Alert fatigue is measured: acceptance drops about 30% for
each extra reminder (Ancker et al. 2017). A watchdog that reports every restart it survived trains
its reader to stop reading it. `NOTIFY_QUIET` and `NOTIFY_URGENT` move statuses between classes.

## The channel

On a hub host, `templates/notify.sh` finds `/usr/local/bin/hub-notify` and uses its lanes: the bot
lane for urgent (the hub bot writes the words itself, so a reply lands in a conversation that can
answer), the card lane for card, the record lane for quiet. No bot token is read or passed.

Everywhere else: `hermes send -t <target>`. It reuses the platform credentials the gateway already
holds, so:

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
