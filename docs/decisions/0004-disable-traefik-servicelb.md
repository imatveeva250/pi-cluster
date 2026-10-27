# 0004: Disable Traefik, ServiceLB and the k3s Helm controller

## Status

Accepted (2026-10-23)

## Context

k3s installs Traefik as the default ingress controller, and ServiceLB to give LoadBalancer Services an address on the node. In this cluster, no Ingress uses Traefik: private apps use the Tailscale ingress class, public apps use Cloudflare tunnels. Traefik's LoadBalancer Service still bound ports 80 and 443 on the node's LAN address and served nothing. Memory is the cluster's bottleneck (about 4 GB on a single Raspberry Pi).

k3s deploys Traefik through its embedded Helm controller, which turns `HelmChart` objects into Helm releases. Flux runs its own Helm controller for the HelmReleases in this repository; the k3s one is not needed for anything else.

## Decision

Disable Traefik, ServiceLB and the k3s Helm controller in `/etc/rancher/k3s/config.yaml`:

    disable:
      - traefik
      - servicelb
    disable-helm-controller: true

All k3s settings live in this file, not in systemd unit flags, so a reinstall with the install script cannot drop them.

## Consequences

- No ingress controller runs on the node, and nothing listens on ports 80 or 443.
- Memory freed: Traefik's 7-day peak working set was 86Mi; the ServiceLB pods were negligible. `free -m` right after the change and a k3s restart: 778Mi available before, 942Mi after; swap 570Mi before, 336Mi after.
- A LoadBalancer Service would get no address. None exist; access goes through Tailscale and Cloudflare tunnels.
- `--disable=helm-controller` had been set as a unit flag and was a no-op: `disable` only accepts packaged components. The real switch is `disable-helm-controller`.
- Removal order matters. With both disabled in one restart, ServiceLB stopped before it could remove its `service.kubernetes.io/load-balancer-cleanup` finalizer from Traefik's Service, so `helm uninstall --wait` hung until the finalizer was removed by hand. On a fresh install this does not apply, because the components are never deployed.
- A host-level `tailscale serve` entry (`veneticapi.tail184043.ts.net` to Traefik's NodePort 30866), left from before the Tailscale operator, was removed with it.
- Four days later (2026-10-27): 1046Mi available, swap 342Mi.
