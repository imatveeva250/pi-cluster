# Cluster status page

- Status: Accepted
- Date: 2026-10-21

## Context

The cluster needs a public page that shows it is running, readable by anyone without access
to the tailnet. Grafana and Prometheus stay private. At the moment, the cluster is a single Raspberry Pi node with 4 GB of RAM, most of it already in use.

## Decisions

### 1. Own application instead of an existing dashboard

A small Python application (FastAPI) in its own repository, `imatveeva250/cluster-status`,
under the MIT license. The existing showcase dashboards reviewed were built for other
clusters, depended on a different monitoring stack, or needed cluster-wide read access to
the Kubernetes API.

- Reuses the Prometheus already running in `monitoring`.
- No ServiceAccount or RBAC: it only sends HTTP requests to Prometheus.
- Stateless: no PersistentVolumeClaim.

### 2. Fixed queries, aggregated numbers, short cache

The backend runs five fixed PromQL queries and returns only aggregated numbers: memory, CPU
and disk usage, running pods, and node uptime.

- Visitors cannot send their own queries, so the public page cannot be used to read cluster
  internals or to load Prometheus with expensive queries.
- Results are cached for 15 seconds. Prometheus receives at most five queries per 15 seconds,
  regardless of traffic.
- No pod names, namespaces or other identifiers are exposed.

### 3. Image build: GitHub Actions on an arm64 runner, published to GHCR

A version tag (`vX.Y.Z`) triggers a build on a native arm64 runner. The image is pushed to
`ghcr.io/imatveeva250/cluster-status` with version tags only; there is no `latest` tag.

- A native arm64 runner avoids emulation and matches the node's architecture.
- The package is public, so the cluster needs no image pull secret.
- This repository pins an exact image tag. A release is a new tag in the application
  repository, followed by an image tag change here.

### 4. Public access: its own Cloudflare tunnel

The same pattern as audiobookshelf: a cloudflared Deployment in the application's namespace,
configured through a ConfigMap, with credentials in a SOPS-encrypted Secret.

- No open ports on the home network.
- The namespace holds only this tunnel's credentials.
- One replica. On a single node, a second replica does not survive a node failure and costs
  memory.
- The cloudflared image is pinned to a release.

Alternative considered: one shared tunnel for all public applications. It uses less memory,
but means changing the existing audiobookshelf setup and sharing one credential across
applications. Not chosen at this point.

### 5. Hardening

- Runs as UID 10001, which matches no user on the node; `runAsNonRoot: true` enforces
  non-root.
- `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, and all capabilities dropped.
- Liveness and readiness probes on `/healthz`, which does not depend on Prometheus. If
  Prometheus is unavailable, the page stays up and says so.
- Memory requests and limits from the first deployment.

## Consequences

- The page is public at `status.matveeva.dev`.
- If Prometheus is unavailable, the page reports that no reading is available instead of
  failing.
- Each release takes two steps: a tag in the application repository, and an image tag change
  in this repository.
- One more tunnel credential to keep in SOPS.
