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
COMMIT=c8a38d9d17e6b864e035bfffac22a6a7e3b53052
SHA256=01eeb1109f0e5daae4f28980cf525f585b8fbe10ecc9dacd7a334f85dd6b7b35
```

`floor/fetch-floor.sh` downloads the file at exactly that commit and refuses it unless the hash
matches. Nothing is written on a mismatch. The fetched copy, `floor/quick-check.sh`, is ignored by git.

A commit, not a branch or a tag, because branches move and tags can be moved; a hash, because a raw
file URL is a network fetch and the thing that restarts your gateway deserves to be verified before it
runs. That commit is the same content as the upstream's `v1.1.0` tag: the order-independent `:443`
liveness probe, which fixed a false "degraded" on healthy idle gateways.

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
