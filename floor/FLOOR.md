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

`floor/PIN` names a commit and the SHA-256 of the file at that commit:

```text
COMMIT=607e798fd68d254cd5006fe3041e8d9df9e6cad5
SHA256=2436985f3201d411416e117acc1785b9f4d06941dcfabc57a6e1eca94aa36839
```

`floor/fetch-floor.sh` downloads the file at exactly that commit and refuses it unless the hash
matches. Nothing is written on a mismatch. The fetched copy, `floor/quick-check.sh`, is ignored by git.

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
2. Put the candidate commit and the new hash into `floor/PIN`
   (`curl -fsSL https://raw.githubusercontent.com/MichaelZelbel/hermes-claude-code-devops-watchdog/<commit>/templates/quick-check.sh | sha256sum`).
3. Run `tests/test-floor-pin.sh`. It fetches and verifies.
4. Commit the two-line change with the reason.

## What the floor decides, and what it does not

It decides one thing: is the gateway alive. Unit active; a warm-up grace after start; an `hermes
gateway status` probe as an early trigger; an outbound `:443` connection held by the gateway process;
the platform handshake logged after the last start; one re-check before restarting. It restarts once
and exits 10. It sends nothing.

Everything else, the diagnosis, the bounded repairs beyond a restart, the reports, is the operator
layer on top, which here is a second Hermes profile. The floor does not know or care who the operator
is, which is why two products can share it.
