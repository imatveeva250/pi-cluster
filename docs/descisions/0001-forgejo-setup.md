# Forgejo setup

- **Status:** Accepted
- **Date:** 2026-10-19

## Context

The cluster needs a self-hosted git server, both for personal repositories and as a
possible base for in-cluster CI (Forgejo Actions). The cluster is a single Raspberry Pi
node with 4 GB of RAM, of which roughly 78% is already in use. The public face of
this project is the GitHub repository, not the self-hosted git server.

## Decisions

### 1. Version: Forgejo 15 LTS

Forgejo publishes a stable release every quarter. LTS releases receive security and bug
fixes for about 15 months; regular releases for about 3 months.

At the time of this decision, 17.0 had been out for four days and is supported until
January 2027. 15.0 LTS is supported until July 2027.

- Forgejo cannot be downgraded. Once a newer version has migrated the database, the only
  way back is restoring a backup. Adopting a release in its first days carries the most
  risk.
- 15 LTS needs one planned major upgrade (to the next LTS) instead of two within six
  months.
- Renovate is configured to propose only patch updates within the 15 line. Major
  upgrades are done by hand, after a verified backup, following a runbook.

**Alternative considered:** 17 (latest). Rejected for the reasons above; its new features
are not needed for a personal git server.

### 2. Access: Tailscale only, no public tunnel

Forgejo is reachable only from devices on the tailnet, through the Tailscale Kubernetes
operator (same pattern as Vaultwarden).

- A public login page attracts automated brute-force and spam sign-ups within days.
- A public instance must be patched immediately on every security release. Behind
  Tailscale, patching is still required, but not an emergency.
- Git over SSH works normally over the tailnet. Through a Cloudflare tunnel, every client
  would need `cloudflared` configured.
- An in-cluster CI runner reaches Forgejo through its Kubernetes Service, so CI does not
  depend on public access.
- Visibility for others is not lost: the public portfolio lives on GitHub, and Forgejo can
  push-mirror repositories there (outbound only, works from behind Tailscale).

**Alternative considered:** public via Cloudflare tunnel. Rejected for now. If it is ever
needed, the plan is: add a tunnel, disable registration, and set `REQUIRE_SIGNIN_VIEW` so
nothing is visible without logging in.

### 3. Image: rootless variant

The `rootless` image runs as UID 1000 instead of starting as root.

- Matches the non-root policy applied to all pods in this cluster.
- Volume ownership is handled by an initContainer, the same pattern used for
  Audiobookshelf, because `fsGroup` has no effect on k3s `local-path` (hostPath) volumes.

### 4. Database: SQLite

- No separate database pod, which saves RAM on a memory-constrained node.
- Forgejo runs as a single replica on a single node, so a client-server database would
  add cost without adding availability.
- Backups cover one PVC instead of two components.

**Trade-off:** SQLite rules out running more than one Forgejo replica. Acceptable while
the cluster has one node; revisit if that changes.

## Consequences

- Forgejo is not reachable from the internet.
- One planned major upgrade per year, documented in a runbook.
- Resource requests and limits are set from the first deployment and tuned from Grafana
  data afterwards.
