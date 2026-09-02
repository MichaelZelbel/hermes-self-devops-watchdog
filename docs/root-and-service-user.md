# The root-plus-service-user layout

The common production shape, and the one the book's server chapter builds: the gateway is a
**system** unit (`/etc/systemd/system/hermes-gateway.service`) installed by root and running as a
service user (`ai` in the book, `hermes` in many installs). Root can restart it; the service user
cannot. The service user owns Hermes, its credential store, and therefore the watchdog profile.

So the three layers run as two users:

| Layer | Runs as | Why |
|---|---|---|
| Floor (`floor/quick-check.sh`) | **root**, root's crontab | `systemctl restart` of a system unit needs root. The floor's probes take `HERMES_USER`, `HERMES_HOME`, `HERMES_BIN` and hop to the service user for the `hermes gateway status` probe with `sudo -n -u`. |
| Self-check (`templates/selftest.sh`) | root's crontab, operator run **as the service user** through `OPERATOR_CMD` | The probe must run under the service user's watchdog profile, where the shared sign-in lives. |
| Operator (`templates/run-prompt.sh`) | same | Same reason; and its writes land in the service user's profile, not root's home. |
| Alerts (`templates/notify.sh`) | `hermes send` **as the service user** through `SEND_CMD` | The platform credentials are in the service user's Hermes. |

## Setup, as root

```bash
AI=ai                                      # the service user
git clone https://github.com/MichaelZelbel/hermes-self-devops-watchdog.git /opt/hermes-watchdog
/opt/hermes-watchdog/floor/fetch-floor.sh
sudo -u "$AI" -H /home/$AI/.local/bin/hermes profile create watchdog --no-skills --no-alias
# the leash, on the watchdog profile (see docs/approvals.md)
```

Root's crontab (`crontab -e` as root):

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AI=ai
HERMES_USER=ai
HERMES_HOME=/home/ai/.hermes
HERMES_BIN=/home/ai/.local/bin/hermes
WATCHDOG_HOME=/home/ai/.hermes/profiles/watchdog
OPERATOR_CMD=sudo -n -u ai -H env HERMES_HOME=/home/ai/.hermes/profiles/watchdog
SEND_CMD=sudo -n -u ai -H
REPO=/opt/hermes-watchdog

*/5 * * * *  /opt/hermes-watchdog/floor/quick-check.sh
*/5 * * * *  /opt/hermes-watchdog/templates/selftest.sh
7 * * * *    /opt/hermes-watchdog/templates/run-prompt.sh hourly-quick-repair
23 */6 * * * /opt/hermes-watchdog/templates/run-prompt.sh six-hour-deep-check
```

Cron passes those variables to every job. The floor restarts the system unit as root; the
operator's one-shots and the alerts run as the service user, under the watchdog profile.

Two more variables matter in this layout, both measured on a live server on 2026-09-02:

- `SEND_HOME=/home/ai/.hermes`: the `HERMES_HOME` that holds the messaging credentials. Without it
  `notify.sh` sends from the caller's own Hermes home, which for root is `/root/.hermes`, and every
  alert fails with "Platform 'telegram' is not configured" while the service user's gateway is fine.
- `GATEWAY_HOME=/home/ai/.hermes`: for the premium kit's watchdog runner, which wraps the floor. It
  also honours `HERMES_USER` and `OPERATOR_CMD` with the same meaning as here, so one env block serves
  the floor, the self-check, the operator runs and the runner alike.

The service user's watchdog profile has its own `.env`. A model credential the gateway keeps as an
environment key (for example `KIMI_API_KEY` in `/home/ai/.hermes/.env`) is not seen by the watchdog
profile until that line is copied into `/home/ai/.hermes/profiles/watchdog/.env`; the shared
`auth.json` covers OAuth credentials only. The self-check names this failure plainly ("No usable
credentials found for provider"), which is how it was found.

## What to watch for

- `sudo -n` must not prompt. Root's cron has no terminal; if `sudo` asks for a password the job
  fails silently. Root running `sudo -u ai` never prompts, so this layout is safe by default.
- Do not run the operator as root "to keep it simple". It would write memory and sessions into
  root's `~/.hermes`, a third Hermes home nobody watches, and it would not share the gateway's
  sign-in, so the self-check would answer a question about the wrong credential.
- The log files default under `/var/log/hermes-watchdog/` and `/var/lib/hermes-watchdog/`, which
  root owns. The service user's own runs (if you also schedule any from its crontab) need their
  own `LOG_FILE` and `STATE_DIR`.

## The single-user layout, for contrast

A gateway installed as a **user** unit by the same account that runs the watchdog needs none of
this: everything runs as that user, `SYSTEMCTL_USER=1` for the floor, `OPERATOR_CMD` and `SEND_CMD`
empty. `templates/cron.example` is written for that case.
