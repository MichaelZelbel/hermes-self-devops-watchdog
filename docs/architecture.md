# Architecture

Three layers on one machine, in order of what must never fail.

```text
1. floor      shell, machine cron     is the gateway alive? restart once if not
2. self-check shell, machine cron     can the watchdog Hermes answer one word?
3. operator   hermes -z, machine cron diagnose, repair within bounds, report
                                       |
                                       v
                          hermes send -t telegram   alert, no model involved
```

## Why the floor is shell

A watchdog exists for the moment something is broken. If the thing that checks is the thing that is
broken, the check reports nothing, and nothing looks exactly like healthy. So the layer that decides
"alive or not" and performs the one repair that fixes most outages (restart the gateway) contains no
model call at all. It is `floor/quick-check.sh`, fetched from its one upstream and hash-verified.

## Why the operator is a second Hermes profile, and what that costs

The operator diagnoses beyond "alive or not": logs, the clock, provider health, disk, memory, the
integrations. On this project the operator is Hermes itself, under `hermes profile create watchdog`:
its own config, memory and sessions, so its notes and the gateway's conversations never mix.

What it does not have is its own credential store, runtime, update channel or model provider. It
shares all four with the gateway it watches. That means correlated failures are possible: when the
provider is rate-limited, or the shared sign-in has expired, the gateway cannot answer and neither can
the operator. The sister project, hermes-claude-code-devops-watchdog, avoids this by putting a
different company's tool on the pager, at the price of a second subscription.

## Why the self-check is mandatory here

Because of the paragraph above. In August 2026 a shared credential expired on a production hub; the
checks that read files kept reporting green for eight days while every repair job died at login. The
probe that would have caught it asks the healer to do one trivial thing, live, and shouts when it
cannot. On this architecture that probe is `templates/selftest.sh`, it runs every five minutes on the
machine's cron, and its alert leads with **SELF-HEALING IS DOWN** and where the fix lands.

## Why nothing here uses `hermes cron`

Hermes has a scheduler, and it is a good one. Its clock lives inside the gateway process. When the
gateway is down, the clock is down, and a slot that was missed is never caught up. A watchdog on that
clock stops at the exact moment it is needed. So the floor, the self-check and the operator's runs all
live on the machine's own cron, as the Hermes user, and `hermes cron` is one of the things they check.

## Why alerts go through `hermes send`

`hermes send -t telegram "text"` reuses the platform credentials the gateway already holds. No bot
token is copied into a second file, no chat id is looked up, no message splitter is maintained, and no
model is involved. If the platform credentials themselves are broken, `notify.sh` says so on stderr
and in its log rather than failing quietly; that case is one of the things the deep check looks for.

## Why the operator's runs are judged by output

`hermes -z "<prompt>"` exits 0 even when it reached no model at all; the error is printed. Every
wrapper here reads what came back. A wrapper that trusted `$?` would report healthy through the outage
it exists to catch.
