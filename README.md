# pi-cluster

Single-node k3s homelab on a Raspberry Pi, managed with GitOps (Flux). Secrets are
encrypted in the repo with SOPS and age.

## Repository layout

| Path | Contents |
|---|---|
| `clusters/staging` | Flux Kustomizations, entry point for the cluster |
| `apps/base` | Base manifests per app |
| `apps/staging` | Staging overlays: ingress, secrets, environment-specific settings |
| `infrastructure/controllers` | Cluster-wide controllers (Renovate) |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| `docs/decisions` | Architecture decision records |

## Decisions

| # | Decision | Summary |
|---|---|---|
| [0001](docs/decisions/0001-forgejo-setup.md) | Forgejo setup | 15 LTS, Tailscale only, rootless image, SQLite |
