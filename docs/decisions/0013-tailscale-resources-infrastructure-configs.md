# 0013: Tailscale resources through a default ProxyClass, in a separate configs layer

## Status

Accepted (2026-11-18)

## Context

Since [0007](0007-tailscale-operator-flux.md) Flux manages the Tailscale operator, but the operator and its four proxy pods (one per Tailscale Ingress: audiobookshelf, Forgejo, Grafana, Vaultwarden) had no resource requests or limits. Every other pod I control has them. On a 4 GB node, pods without requests are the ones the scheduler and the eviction logic know least about.

Measured over 7 days before the change: the operator peaked at 58 MiB (37 MiB normally), the proxies at 42 MiB (21 to 23 MiB normally).

The proxies are not in the chart's templates. The operator creates a StatefulSet for each Ingress, so their pod settings can't be set with chart values. The operator reads them from a `ProxyClass`, a custom resource whose CRD comes from the chart.

The HelmRelease had no `values:` block: all values came from the SOPS-encrypted Secret through `valuesFrom`, because the chart renders the OAuth credentials from values.

## Decision

- **Operator resources in a plain `values:` block** in the HelmRelease (`operatorConfig.resources`): requests 10m CPU and 48Mi memory, limit 128Mi. Flux merges `valuesFrom` first and `values` on top, so the OAuth values stay encrypted and the resources stay readable in Git. Resources are not secrets.
- **Proxy resources in a cluster-scoped `ProxyClass` named `default`**: requests 10m CPU and 32Mi memory, limit 128Mi (generous on purpose: 84 MiB was seen once in October). The chart value `proxyConfig.defaultProxyClass: default` makes the operator use it for every Ingress without a class of its own, so new Tailscale Ingresses get resources without extra configuration.
- **A new Flux Kustomization, `infrastructure-configs`**, for objects that use CRDs installed by `infrastructure-controllers`. It `dependsOn` `infrastructure-controllers`, which now has `wait: true`, so it is only Ready when its HelmReleases are healthy and the CRDs exist. This is the same split as `monitoring-controllers` and `monitoring-configs`. If the `ProxyClass` sat next to the HelmRelease, a rebuild from scratch would apply it before Helm installed the CRD, and the whole Kustomization would fail with `no matches for kind "ProxyClass"`.
- **Two pull requests, in order**: first the `ProxyClass` (it existed, nothing used it, nothing restarted), then the default class in the chart values. The other way round, the operator would have pointed the proxies at a class that didn't exist yet.

## Consequences

- Every pod from a manifest or chart I control now has requests and limits.
- Setting the default class restarted all four proxies once (a few seconds without tailnet access per app). Their tailnet names stayed the same.
- `apps` already `dependsOn` `infrastructure-controllers`. With `wait: true` the apps now also wait until the Tailscale operator is healthy, which helps the rebuild drill: the Tailscale Ingresses have something to serve them.
- `infrastructure-controllers` takes a little longer to become Ready, because Flux now checks the health of its objects instead of only applying them.
- The operator's settings are in two places: OAuth in the encrypted Secret, everything else in `values:`.
- Before each change I rendered the chart with the old and new values and compared them. The render doesn't need the OAuth values: they are the same on both sides, so the diff only shows the change.
- Alternatives considered:
  - **Resources inside the encrypted values Secret.** One values source, but nobody can read the resources without decrypting, and every change is a SOPS edit.
  - **A `ProxyClass` set per Ingress** (`tailscale.com/proxy-class` label). More control per app, but four places to keep in sync, and a new Ingress without the label gets no resources.
  - **The `ProxyClass` in `infrastructure-controllers`.** Works on the running cluster, fails on a fresh one (see above).
