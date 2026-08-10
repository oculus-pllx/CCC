

<!-- CCC:DEPLOYMENT:START -->
## CCC Deployment Target (machine-local, not in repo)

- **This machine (ccc-dev, 192.168.0.53) IS the test machine.** It is itself a
  CCC-provisioned workstation. Do NOT try to SSH to root@192.168.0.53 — that is
  this very box, and root SSH login is disabled; it will always fail.
- **To deploy/test a pushed commit:** run `sudo ccc-self-update` locally.
  Claude sessions on this box HAVE passwordless sudo (verified 2026-06-13), so
  Claude can run `sudo ccc-self-update` directly — no need to ask the user. The
  enabled auto-update cron (daily 3 AM, /etc/cron.d/ccc-app-update) also covers it.
- Installed version marker: /etc/ccc/version (compare with `git log`).
- Development and GitHub pushes happen on **this machine only**.
- Do **not** create new SSH keys.
- The key at /etc/ccc/project-keys/CCC/id_ed25519 is not currently authorized
  anywhere; leave it alone. Do **not** `chmod` or `chown` project keys. They are
  intentionally root-owned and group-readable (0640, group `ccc`) so every team
  member shares one key; "tightening" to 0600 breaks access and will be reverted.
<!-- CCC:DEPLOYMENT:END -->
