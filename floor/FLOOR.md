# The shared floor

`quick-check.sh` is the deterministic layer: every five minutes it decides from activity-independent
signals whether the gateway is alive, and restarts it once if not. No model is consulted. It is the
part of a watchdog that must keep working through every outage the model can have.

It is maintained in **one** place, the
[hermes-claude-code-devops-watchdog](https://github.com/MichaelZelbel/hermes-claude-code-devops-watchdog)
repository, at `templates/quick-check.sh`, and consumed here. This repository never carries a copy of
it and never edits it. Two copies drift; the author's own installers once drifted until 212 of 309
lines differed, and `kit-bootstrap` exists to end that.

## How it is consumed

`floor/PIN` names a commit and the SHA-256 of each file at that commit:

```text
COMMIT=d4166c20e7ee404b48cf8b72e5832999b79ae1ee
SHA256=81d343cf1f081611595fe1caad5407a1be2a22799a1077cf8ecabfc31e7361a4
STALE_SHA256=e38f18fbd1a49cccc414b87094c8055f38a39d727c3203ddb0d6b9a59ee0d50a
```

`floor/fetch-floor.sh` downloads both files at exactly that commit and refuses them unless both hashes
match. Nothing is written on a mismatch, not even the file that matched. The fetched copies,
`floor/quick-check.sh` and `floor/stale-check.sh`, are ignored by git.

A commit, not a branch or a tag, because branches move and tags can be moved; a hash, because a raw
file URL is a network fetch and the thing that restarts your gateway deserves to be verified before it
runs. That commit is the upstream's `v1.1.0` content (the order-independent `:443` liveness probe,
which fixed a false "degraded" on healthy idle gateways) plus one guard, on the upstream branch
`floor/no-platform-guard`, merged to `main` on 2026-09-02 (main is 607e798): when the Hermes `.env` holds no messaging
platform token, probes B and C are skipped, because a gateway with no platform holds no `:443`
connection and logs no handshake, and the floor would otherwise restart a healthy gateway on every
tick. Measured on 2026-09-02 on a Telegram-less test gateway before the guard existed.

## Moving the pin

1. Read the upstream diff between the pinned commit and the candidate.
2. Put the candidate commit and both new hashes into `floor/PIN`
   (`curl -fsSL https://raw.githubusercontent.com/MichaelZelbel/hermes-claude-code-devops-watchdog/<commit>/templates/<file> | sha256sum`
   for `quick-check.sh` and `stale-check.sh`).
3. Run `tests/test-floor-pin.sh`. It fetches and verifies.
4. Commit the three-line change with the reason.

## What the floor decides, and what it does not

It decides one thing: is the gateway alive. Unit active; a warm-up grace after start; an `hermes
gateway status` probe as an early trigger; an outbound `:443` connection held by the gateway process;
the platform handshake logged after the last start; one re-check before restarting. It restarts once
and exits 10. It sends nothing.

Everything else, the diagnosis, the bounded repairs beyond a restart, the reports, is the operator
layer on top, which here is a second Hermes profile. The floor does not know or care who the operator
is, which is why two products can share it.

Pinned since 2026-09-02 at upstream `2abd1c2` (main): probe B reads the unit's own `MainPID` before
falling back to `pgrep`. On a host running several Hermes gateways as one user the old lookup judged a
healthy unit by another gateway's sockets and restarted it on the first tick; found on the author's
fourteen-gateway server the day the kit went on its pager.

Pinned since 2026-09-02 (later the same day) at upstream `d7e26ca` (main): probe C reads the rotated
`agent.log.1` before the current log, so the newest "Connected" line is the one compared against the start
time. The old order returned a days-old line after any restart on a host with a rotated log, and the floor
restarted a healthy, connected gateway on every tick: four restarts in seventeen minutes on the author's
server before it was caught.

## Two files at one commit (since v1.0.13)

Since upstream `v1.2.0` the floor is two files. `stale-check.sh` answers a question `quick-check.sh`
cannot: is a gateway that is up running older code or settings than are on disk? That happens when the
Hermes files change under a running gateway. Python keeps the code it already loaded and loads the rest
fresh, so old and new code meet, and the gateway answers every message with an error while every
liveness signal says it is fine. One restart fixes it.

It is a separate script, not a change to `quick-check.sh`, because the floor's contract stays "is it
alive, restart once if dead". Staleness has its own cron line, its own state, its own one-hour cooldown
and its own lock, so a bug in one cannot turn into restarts by the other. Both are pinned at one commit
and verified together, so the two never come from different versions.

Pinned since v1.0.14 at upstream `v1.2.1` (`d4166c2`), a security fix. Run as root, `stale-check.sh`
wrote its drain marker and asked the `hermes` CLI as root, inside files the Hermes user controls. A
symlink or a program that user planted could give it root. Both now run as the Hermes user.
