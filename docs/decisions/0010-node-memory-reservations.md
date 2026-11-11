# 0010: Reserve node memory and evict before the node starves

## Status

Accepted (2026-11-11)

## Context

The node has 4 GB of RAM, and memory is what runs out first. On 2026-11-11 a single Renovate run (about 600Mi) started right after several rollouts. The node started reading memory pages back from disk, and everything slowed down at once. CoreDNS answered its liveness probe too slowly (timeout 1s) and the kubelet killed it, the node was NotReady for about a minute, and my PublicEndpoint operator stopped checking until I restarted it. The previous CoreDNS restart, on 2026-10-21, fell on another Renovate memory peak.

Two settings made this possible:

- **No memory eviction.** k3s sets its own kubelet eviction thresholds, and they cover only disk (`nodefs.available<5%`, `imagefs.available<5%`). The kubelet had no threshold to evict a pod for memory, so it could only watch the node run out.
- **Nothing reserved.** Allocatable was equal to all RAM (4146304Ki). The scheduler counted memory that k3s and the operating system were already using as free for pods.

What uses the memory, measured on 2026-11-11:

| Consumer | Memory |
|---|---|
| `k3s-server` (API server, scheduler, controller manager, datastore) | about 990Mi RSS; heap in use 795Mi, live data about 430Mi |
| All pods together | 1773Mi; requests 1968Mi |
| Prometheus | about 600Mi |
| Grafana's two sidecars | 202Mi (more than Grafana, 93Mi) |
| containerd | about 106Mi |
| Graphical desktop on the Pi | 57Mi |

The API server's data is small (about 1,000 objects, Helm release Secrets 3.7 MiB, datastore 45 MiB), so the k3s memory is not caused by objects piling up.

## Decision

Reserve memory for the system and for k3s, give the kubelet a memory eviction threshold, and make k3s's Go runtime collect garbage earlier.

- **kubelet arguments** in `/etc/rancher/k3s/config.yaml`:
  - `kube-reserved=memory=800Mi`: k3s itself after the change below, plus containerd
  - `system-reserved=memory=300Mi`: the operating system, sshd, tailscaled, journald
  - `eviction-hard=memory.available<200Mi,nodefs.available<5%,imagefs.available<5%`
  - `eviction-minimum-reclaim=imagefs.available=10%,nodefs.available=10%`

  Setting `eviction-hard` replaces all of the kubelet's eviction defaults, so the two disk signals k3s already used are listed again with the same values.
- **`GOMEMLIMIT=700MiB` for k3s.** Without a limit, Go lets the heap grow to about twice the live data before collecting (`next_gc` was 860Mi for about 430Mi of live data). The limit makes it collect earlier. It is soft: if live data grows past it, the garbage collector works harder instead of crashing. It is set in a systemd drop-in, `/etc/systemd/system/k3s.service.d/memory.conf`, because the k3s install script rewrites the unit and its environment file.
- **The Pi boots into `multi-user.target`.** The desktop was not used. It freed 57Mi.

Before restarting k3s I checked that the pods fit under the new limits: 1773Mi in use plus one Renovate run (about 600Mi) is below the new 2949Mi cap for all pods, and the existing requests (1968Mi) fit in the new allocatable.

## Consequences

- Allocatable is now 2815104Ki (2749Mi): 4049Mi minus 800Mi, 300Mi and the 200Mi eviction threshold. The scheduler no longer places pods on memory that k3s is using.
- All pods together are capped at about 2949Mi by their cgroup (`enforce-node-allocatable=pods` is the default). A pod that pushes past it is OOM-killed instead of slowing down the whole node.
- Below 200Mi available, the kubelet evicts pods, starting with the one furthest above its memory request. That is Renovate (request 256Mi, about 600Mi used), which is the right pod to lose: its next run retries.
- `k3s-server` dropped from about 990Mi to about 715Mi RSS right after the restart. Part of that is any restart; whether it stays below about 800Mi is only known after a few days.
- Requests can grow by about 780Mi before new pods stop being scheduled. A new app now has to fit into what is left.
- The eviction path has not been triggered on purpose. The first real test is the next Renovate run under pressure; `kubectl get events -A | grep -i evict` shows it.
- The node configuration (`config.yaml` and the drop-in) is not in Git yet. A rebuilt node would come back without these settings.
- Alternatives considered:
  - Raising CoreDNS's probe timeouts treats the symptom, and k3s re-applies its CoreDNS manifest on every restart.
  - Lowering Renovate's memory limit below what it needs would get it OOM-killed on every run.
  - Moving Renovate off the node would remove the spike itself, but it changes how dependency updates run and is a separate decision. The node still needs a memory threshold for whatever comes next.
