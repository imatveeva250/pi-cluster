# pi-cluster

Single-node k3s homelab on a Raspberry Pi, managed with GitOps (Flux). Secrets are
encrypted in the repo with SOPS and age.

## Repository layout

| Path | Contents |
|---|---|
| `clusters/staging` | Flux Kustomizations, entry point for the cluster |
| `apps/base` | Base manifests per app |
| `apps/staging` | Staging overlays: ingress, secrets, environment-specific settings |
| `infrastructure/controllers` | Cluster-wide controllers (Renovate, PublicEndpoint operator) | | `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| `docs/decisions` | Architecture decision records |
| `docs/postmortems` | Incident write-ups |

## Decisions

| # | Decision | Summary |
|---|---|---|
| [0001](docs/decisions/0001-forgejo-setup.md) | Forgejo setup | 15 LTS, Tailscale only, rootless image, SQLite |
| [0002](docs/decisions/0002-cluster-status.md) | Cluster status page | Own app, fixed Prometheus queries, arm64 image via GitHub Actions, public through its own tunnel |
| [0003](docs/decisions/0003-publicendpoint-operator.md) | PublicEndpoint operator | Own CRD and kopf operator, scoped RBAC, endpoints declared per app |
| [0004](docs/decisions/0004-disable-traefik-servicelb.md) | Disable Traefik, ServiceLB and the k3s Helm controller |
| [0005](docs/decisions/0005-alerting-telegram.md) | Alert delivery through Telegram |
| [0006](docs/decisions/0006-flux-alerts-kube-state-metrics.md) | Flux resource alerts through kube-state-metrics |

## Postmortems

| Date | Incident |
|---|---|
| [2026-10-22](docs/postmortems/2026-10-22-renovate-images.md) | Node disk filled by unpinned Renovate images |
| [2026-10-22](docs/postmortems/2026-10-22-grafana-stuck-rollout.md) | Grafana rollout stuck for 71 days on a missing Secret key |
