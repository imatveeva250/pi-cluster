# 0012: Automatic Debian updates on the node, reboots stay manual

## Status

Accepted (2026-11-17). Revisit when the second node arrives.

## Context

On 2026-11-17 the node had been up for 145 days and was 379 packages behind, including openssl. Patching depended on me remembering to do it. The patch session itself went well ([runbook](../runbooks/patch-the-node.md)), but between sessions security fixes waited for months.

The node is a single Raspberry Pi. A reboot takes the whole cluster down for a few minutes, so I don't want reboots to happen while nobody is watching.

Raspberry Pi OS takes packages from two places:

- Debian's own repositories, including `trixie-security`.
- Raspberry Pi's repository (`archive.raspberrypi.com`): the kernel, the firmware, and Raspberry Pi's own builds of some Debian packages. openssl is one of them (`3.5.9-1~deb13u1+rpt1`, only available from that repository). This repository doesn't label anything as a security update.

k3s is not an apt package (it was installed with its install script), so apt never changes Kubernetes itself.

## Decision

Install `unattended-upgrades` and let it install Debian updates every day, without rebooting. Everything else stays in the manual patch session, which also does the reboot.

- **What it installs:** Debian's default origins, which I kept: Debian stable updates (point releases, reviewed by the Debian release team) and `trixie-security`. Not the Raspberry Pi repository and not `pkgs.tailscale.com`.
- **No automatic reboot:** `Unattended-Upgrade::Automatic-Reboot "false"` in `/etc/apt/apt.conf.d/52unattended-upgrades-local`. That is the default already; the file makes the decision visible on the node. It is a separate file because the package's own `50unattended-upgrades` is a conffile: editing it would make every package upgrade ask which version to keep.
- **When:** a systemd timer drop-in, `/etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf`, moves the daily run to 04:30 (plus up to 15 minutes random delay), between the 03:30 backup and Renovate's 07:00 run. The default was 06:00 plus up to an hour, which could overlap with Renovate, the node's biggest memory spike. The drop-in starts with an empty `OnCalendar=`, because `OnCalendar` is a list and a drop-in would otherwise add to it.
- **Manual patch session**, about monthly, with the runbook: Raspberry Pi packages (kernel, firmware, openssl), Tailscale, the reboot, and removing unused images.

## Consequences

- Debian fixes land within a day instead of waiting for the next session.
- A library update only takes effect when the processes using it restart. Until the next reboot some processes keep running the old version.
- Security fixes from the Raspberry Pi repository, openssl among them, still wait for the manual session. Missing a month means missing those fixes.
- Something can change on the node without me watching. If a Debian update breaks something, the cause is in `/var/log/unattended-upgrades/` and `/var/log/apt/history.log`.
- Changing the timer's schedule made it run once right after `daemon-reload` (the timer is `Persistent=true`, and with the new schedule a run counted as missed). It found nothing to install.
- The node configuration is still not in Git (see [0010](0010-node-memory-reservations.md)). These two files join the list for the rebuild drill.
- Alternatives considered:
  - **Manual patching only.** Every change is watched, but it depends on remembering, which is how the node reached 145 days.
  - **Automatic reboots too.** Fully hands-off, but on a single node that is unwatched downtime. With two nodes, one can be drained and rebooted while the other runs the pods; that is when to revisit this.
  - **Adding the Raspberry Pi repository to the allowed origins.** It would cover openssl, but also the kernel and firmware, which need a reboot and are the riskiest updates on a Pi. They stay in the watched session.
