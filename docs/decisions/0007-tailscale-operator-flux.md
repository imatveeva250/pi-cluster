# 0007: Manage the Tailscale operator with Flux

## Status

Accepted (2026-10-28)

## Context

The Tailscale Kubernetes operator gives the private apps (Forgejo, Vaultwarden, Grafana, audiobookshelf) their tailnet addresses: each Tailscale Ingress gets a proxy pod with its own device on the tailnet. It was installed in August with `helm install`, outside Git. Everything else in the cluster comes from this repository through Flux.

Being outside Git had three costs:

- A rebuild from Git would bring back every app, but nothing to serve their Tailscale Ingresses.
- Renovate scans the repository, so it could not see the operator, and nothing proposed updates. The operator was still on 1.98.9 when the October security advisories called for an upgrade.
- The OAuth client credentials existed only in the cluster.

The chart renders the Secret `operator-oauth` from two values, `oauth.clientId` and `oauth.clientSecret`, so Helm owns that Secret.

## Decision

Flux manages the operator through a HelmRepository and a HelmRelease in `infrastructure/controllers/base/tailscale-operator/`, and adopted the existing release instead of reinstalling it.

- **Adoption, not reinstall.** Helm keeps release state in the cluster, as Secrets in the release namespace. Flux's helm-controller reads the same Secrets, so a HelmRelease with the same release name (`releaseName: tailscale-operator`, set explicitly) and namespace takes over the existing release with an upgrade. A reinstall would have created new proxy devices with new names, and broken URLs that depend on them, such as Forgejo's `ROOT_URL`.
- **The adoption changes nothing.** Same chart version (pinned), same values, no other changes in the same commit. Before pushing, the manifests Helm was running (`helm get manifest`) were compared with what the chart renders from the same values (`helm template`). Improvements to the release come in later commits, as ordinary Flux upgrades.
- **OAuth values come from a SOPS-encrypted Secret through `valuesFrom`.** The chart keeps rendering `operator-oauth` exactly as before. Replacing it with a separately managed Secret of the same name would not work: once the chart stops rendering it, Helm deletes it on the next upgrade, and the operator loses its credentials. The values Secret was built from the live values in RAM (`/dev/shm`) and encrypted before it entered the repository, and compared byte for byte with the live values.
- **The namespace is in Git**, with the label it already had, so a rebuild recreates it the same way.

## Consequences

- No proxy restarted, and no Tailscale address changed. The operator itself restarted once: the earlier manual upgrade had used `helm upgrade --reuse-values`, which keeps the old values and does not add defaults that the new chart version introduced. One new setting (`OPERATOR_SHARED_ACME_ACCOUNT_KEY`) had rendered empty, and Flux, which always renders chart defaults plus values, wrote it as `"false"`. The diff before pushing found this.
- Renovate now sees the chart and proposes updates as pull requests. This needed its `flux` manager to scan HelmRelease files, which it did not do by default.
- `helm list -A` and `flux get helmreleases -A` now show the same releases: nothing in the cluster is installed by hand.
- Deleting the HelmRelease from Git would uninstall the operator, and deleting the namespace would remove every proxy's device state.
- The OAuth credentials now exist in two places: encrypted in Git, and in the cluster.
- Device state still lives in Secrets that the operator writes, not in Git. A rebuild needs the old devices removed in the Tailscale admin console first, or the new proxies get suffixed names.
- The operator and its proxies have no resource requests or limits.
- Alternatives: keeping the Helm CLI (the problems above remain), or committing `helm template` output as plain manifests (chart upgrades become manual re-renders, and Renovate cannot follow them).
