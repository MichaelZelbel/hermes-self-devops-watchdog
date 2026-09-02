# Security Policy

This repository gives a Hermes profile limited DevOps authority over the Hermes gateway on the same
machine, with a shell floor under it.

## Important safety notes

- Do not paste secrets, tokens, private IPs, chat ids, or production config into issues or PRs.
- The watchdog profile shares the credential store with the gateway. Treat `auth.json`, `.env`,
  `config.yaml`, memories, sessions and chat logs as sensitive in both homes.
- Apply the conservative approvals template first, read its reports, and promote to the autonomous
  one only after testing. Unattended runs are refused a dangerous command, never asked.
- Never disable the self-check. On this architecture it is the only thing that tells you the healer
  is dead.
- The floor is fetched from one upstream at a pinned commit and verified by hash. Do not edit the
  fetched copy; move the pin on purpose.
- Keep firewall, SSH, auth, token rotation, provider credentials, model changes, major updates and
  rollbacks behind explicit human approval.

## Reporting security issues

Open a private security advisory if available, or contact the repository owner privately. Do not
disclose secrets or exploitable deployment details in public issues.
