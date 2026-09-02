# Agent Start: Hermes Self Watchdog

Use this file as the starting point when asking a Hermes profile to configure itself as the DevOps
watchdog for the Hermes Agent server it lives on.

## Goal

Configure this Hermes profile as a safe DevOps watchdog for the Hermes gateway on this machine.

The watchdog periodically verifies gateway health, scheduled jobs, provider authentication and host
pressure; performs only clearly safe repairs; and escalates risky changes to the operator. The checks
that must never fail are shell scripts on the machine's own cron, not you. You are the diagnosis and
the bounded repair on top of that floor.

## What is different about watching yourself

You share a runtime, a config store, a credential store, an update channel and a model provider with
the thing you watch. When the provider is down, or the shared sign-in has expired, you cannot answer
either. So:

1. The floor (`floor/quick-check.sh`) restarts a dead gateway without you.
2. The self-check (`templates/selftest.sh`) asks you to say one word every five minutes, and alerts
   **SELF-HEALING IS DOWN** when you cannot. Never disable it.
3. Your own runs are one-shots (`hermes -z`) under this profile, and the wrapper judges them by their
   **output**, because a one-shot that reached no model exits 0.

## First steps

1. Read these files in this repository:
   - `README.md`
   - `AGENTS.md`
   - `hermes-devops-runbook.md`
   - `docs/architecture.md`
   - `prompts/hourly-quick-repair.md`

2. Confirm which profile you are. `hermes profile list` shows the active one. You should be the
   `watchdog` profile, not the default one the gateway runs under. If you are the default profile,
   stop and tell the operator: the watchdog needs its own profile so its memory and sessions never
   mix with the gateway's.

3. Identify the Hermes installation without revealing secrets. Common paths: `~/.hermes` (or
   `HERMES_HOME`), `~/.local/bin/hermes`, `/etc/systemd/system/hermes-gateway.service` for a system
   unit or `~/.config/systemd/user/hermes-gateway.service` for a user unit.

4. Run a manual dry run of the quick repair workflow.

5. If the dry run succeeds, propose the machine's cron lines from `templates/cron.example`. Do not
   propose `hermes cron` for the floor or the self-check: the gateway's own clock stops when the
   gateway does, which is exactly the moment the floor must run.

## Safety boundaries

Do not do any of these without explicit operator approval:

- Change firewall, SSH, Tailscale, public exposure, or auth settings.
- Rotate, reveal, or copy secrets or tokens.
- Delete data, sessions, memories, logs, backups, or provider auth files.
- Install or remove OS packages.
- Reboot the server.
- Update Hermes.
- Change Hermes config, model or provider defaults, approvals, platform tokens, cron jobs, webhooks
  or MCP servers, in your own profile or the gateway's.

Read-only checks are allowed.

If the gateway is clearly down and it is installed as a managed service, you may restart it once:

```bash
hermes gateway restart          # user service
sudo hermes gateway restart --system   # system service, only if you have that right
```

After restarting, verify with `hermes gateway status` and report what happened.

If Hermes is running as a foreground process, inside tmux or screen, in Docker, or in an interactive
terminal, do not kill or restart that process. Collect evidence and ask first.

## Manual dry-run checks

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

Do not print secrets from `.env`, `auth.json`, provider credential files, Telegram tokens, or chat
transcripts.

## Report back

After the dry run, report:

1. whether the gateway is healthy, read from Hermes and not from systemd alone,
2. which commands worked,
3. any warnings or blockers,
4. whether this environment is suitable for scheduled watchdog runs,
5. which schedule you recommend.

## Recommended schedule

All on the machine's cron, as the Hermes user:

- every 5 minutes: `floor/quick-check.sh` and `templates/selftest.sh`,
- hourly: the quick repair prompt, as a one-shot under this profile,
- every 6 hours: the deep check prompt,
- weekly or by hand: the update maintenance prompt.

Every scheduled task is quiet when healthy and speaks only for a repair, an incident, or an approval
request, through `templates/notify.sh`.
