# Hermes Self DevOps Watchdog

Hermes watching Hermes. A DevOps watchdog for a Hermes Agent server where the operator that
diagnoses and repairs is **a second, isolated Hermes** on the same machine, and where the checks
that must never fail are **plain shell**, not an AI.

This is the sister project of
[hermes-claude-code-devops-watchdog](https://github.com/MichaelZelbel/hermes-claude-code-devops-watchdog),
which puts a different company's tool on the pager. The two share one deterministic floor and differ
in who holds the phone. Read [Which one do you want?](#which-one-do-you-want) before choosing.

## TL;DR

1. Install Hermes Agent on your VPS, as the user that will run the gateway.
2. Give the watchdog its own Hermes: `hermes profile create watchdog`. Same program, own config, own
   memory, own sessions. Same credential store, and that sentence is the reason the self-check below
   is not optional.
3. Fetch the shared floor (one shell script, pinned and hash-checked), and put it on the machine's
   own cron. **Not** on `hermes cron`: the gateway's clock cannot be the thing that watches the gateway.
4. Ask the watchdog Hermes to configure itself:

```text
Configure yourself as the Hermes watchdog for this server. Start here: https://raw.githubusercontent.com/MichaelZelbel/hermes-self-devops-watchdog/main/AGENT_START.md
```

`AGENT_START.md` carries the safety boundaries, the dry-run checks and the recommended schedule.

## The shape

```text
machine cron (every 5 min)  ->  floor/quick-check.sh   (shell: is the gateway alive? restart once if not)
machine cron (every 5 min)  ->  templates/selftest.sh   (shell: can the watchdog Hermes answer at all?)
machine cron (hourly, 6h)   ->  hermes -z "<prompt>"    (the watchdog Hermes: diagnose, repair within bounds, report)
any of the above            ->  hermes send -t telegram (alert; no model, no agent loop)
```

Three layers, and the order is the argument:

- **The floor is shell.** `quick-check.sh` decides whether the gateway is alive from activity-independent
  signals (unit active, a held `:443` connection, the platform handshake after the last start) and
  restarts it once. No model is consulted. It keeps working through every outage the model can have.
- **The self-check is shell, and it probes the healer.** `selftest.sh` asks the watchdog Hermes to say
  one word. If it cannot, the alert says **SELF-HEALING IS DOWN** and nothing else in the report can
  be trusted to repair itself. This exists because of a real week in August 2026 when a shared
  credential expired and every repair job died at login while the checks kept reporting green.
- **The operator is Hermes.** Hourly and six-hourly, a one-shot `hermes -z` run reads the runbook,
  runs the checks, repairs only what the runbook allows, and reports through `hermes send`. It runs
  under its own profile so its memory and sessions never mix with the gateway's.

## Which one do you want?

| | This project | hermes-claude-code-devops-watchdog |
|---|---|---|
| Operator | A second Hermes profile on the same machine | Claude Code, a different company's tool |
| Extra spend | None: the same subscription that runs the gateway | A second subscription or per-token billing |
| Independence | Shares runtime, config store, credential store, update channel and model provider with the patient. Correlated failures are possible and the self-check exists to catch them | Genuinely separate entity holding the pager |
| Floor | Shared, identical | Shared, identical |

If you already pay for the other tool and want the stronger separation, use the sister project. If you
want one subscription and no extra spend, use this one, and keep the self-check on.

## Manual VPS validation

Before scheduling anything, run these as the Hermes user and read them:

```bash
hermes status
hermes doctor
hermes gateway status
hermes cron status
hermes cron list
hermes logs --since 1h
hermes logs errors --since 24h
ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'
df -h
df -i
free -h
uptime
```

Healthy looks like: `hermes gateway status` says the gateway is running; `hermes cron status` says the
clock will fire; the expected messaging platform holds a connection; disk below 80%; no sustained
memory or load pressure. Read the gateway's health from Hermes, never from `systemctl is-active`
alone: a cleanly stopped gateway reads "failed" to systemd.

## One finding that shapes every script here

**A Hermes one-shot that reaches no model at all still exits 0.** The error goes to stdout:

```text
API call failed after 3 retries: HTTP 429: Rate limit reached for this account.
```

and the exit status says success. Every shell wrapper in this repository therefore tests the **output**,
never `$?`. A floor that trusted the exit code would report healthy through exactly the outage it
exists to catch. See `templates/selftest.sh`.

## Files

- `AGENT_START.md`: where the watchdog Hermes starts; boundaries, dry run, schedule.
- `AGENTS.md`: the rules Hermes reads by name when it works in this repository.
- `hermes-devops-runbook.md`: operational policy, what may be repaired without asking, what may not.
- `floor/FLOOR.md` and `floor/fetch-floor.sh`: the shared deterministic floor, fetched from its one
  upstream at a pinned tag and verified by hash. Never edited here.
- `prompts/hourly-quick-repair.md`, `prompts/six-hour-deep-check.md`, `prompts/update-maintenance.md`:
  the three operator prompts.
- `templates/selftest.sh`: the healer liveness probe.
- `templates/notify.sh`: alerts through `hermes send`, quiet on success.
- `templates/hermes-approvals.conservative.example.yaml` and
  `templates/hermes-approvals.autonomous-devops.example.yaml`: the leash for the watchdog profile.
- `templates/cron.example`: the machine's crontab lines.
- `docs/architecture.md`, `docs/approvals.md`, `docs/troubleshooting.md`, `docs/alerts.md`.
- `tests/`: shell tests for the probes and the guards, no network, safe anywhere.

## Support this project

This watchdog is free and MIT licensed, and it stays that way.

If it saved you time, you can buy me a coffee on Ko-fi. Supporters also get the Hermes Self DevOps Kit,
the extended version with the doctor, the security layer, backups, cost observability and the
incident playbooks, operated by the same watchdog Hermes.

## Safety principle

The watchdog Hermes may repair within narrowly scoped boundaries, and must not perform destructive,
security-sensitive or broad system changes on its own. Restarting an installed gateway service after
evidence is safe. Deleting unknown data, changing auth, firewall or SSH, updating Hermes, or editing
config are not, and the approvals templates here refuse them rather than queue them, because a
scheduled run has nobody to answer a question.
