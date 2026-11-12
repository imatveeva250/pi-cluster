# CoreDNS restarted and the node went NotReady under memory pressure

- Date: 2026-11-11
- Impact: cluster DNS was gone for about a minute and the node was NotReady for about a
  minute. My PublicEndpoint operator stopped checking for about 12 minutes, until I
  restarted it, and its last result was a false "down". One cloudflared pod restarted. When
  I checked from outside, both public endpoints answered.

## What happened

All times are Amsterdam time (UTC+1).

- 03:49 to 04:05: I merged four Renovate updates one after another: Vaultwarden 1.37.5,
  cloudflared 2026.10.7 in both tunnels, the Tailscale operator 1.104.4 (which also
  replaced its four proxies), and a newer Renovate image. Each rollout pulled new images
  and started new pods.
- 04:12: I started one Renovate run by hand, to check the new Renovate image. A run uses
  about 600Mi.
- About 04:14: CoreDNS started failing its readiness probe (timeout 1 second).
- 04:15 to 04:16: the operator's checks of the public URLs still succeeded, but took 1.5,
  4.8 and 2.0 seconds instead of the usual 0.15 to 0.3.
- 04:17:21: after three failed liveness probes, the kubelet killed CoreDNS (`Completed`,
  exit code 0: a clean stop, not an OOM kill).
- 04:17:25: the operator's next check failed with `Temporary failure in name resolution`.
  Writing the result to the API server failed the same way, because the operator reached
  the API server by its DNS name. Renovate failed to push one branch for the same reason.
- About 04:18: the node was NotReady; the kubelet had stopped reporting. audiobookshelf's
  cloudflared restarted once around the same time.
- About 04:18:30: CoreDNS was running again, and the node recovered.
- 04:18:37 and 04:18:53: the operator gave up writing status after nine attempts, one
  object after the other. Its timers did not run again.
- Shortly after: `ContainerRestarted` for CoreDNS arrived in Telegram.
- About 04:25: `PublicEndpointDown` arrived.
- About 04:28: `PublicEndpointCheckStale` arrived.

I checked from my laptop: both public URLs answered 200, and `kubectl get pe` showed both
endpoints reachable but last checked ten minutes earlier. The operator's pod was running
and its health endpoint answered, but it was not checking anything. I saved its log and
deleted the pod; the new pod checked both endpoints within seconds, and both alerts
resolved.

The Renovate run itself finished all four repositories.

## Why

- **The node ran out of memory.** On 4 GB, the base load is already high: k3s about
  990Mi, Prometheus about 600Mi, Grafana's two sidecars about 200Mi, all pods together
  about 1.8Gi. The rollouts had just started new pods, and the Renovate run added about
  600Mi on top. The node started reading memory pages back from disk, and everything
  slowed down at once: CoreDNS, the API server and the kubelet itself.
- **Nothing was allowed to evict a pod for memory.** k3s sets its own kubelet eviction
  thresholds, and they only cover disk. Allocatable was equal to all RAM, with nothing
  reserved for k3s or the operating system. So the kubelet could not stop Renovate; it
  could only wait until the node starved.
- **CoreDNS was the first victim.** Its probes allow 1 second. A slow answer from a healthy
  process counts as a failure, so the kubelet killed it, and every pod lost DNS for about a
  minute.
- **The operator depended on DNS to talk to Kubernetes.** kopf's built-in login uses
  `https://kubernetes.default.svc`, not the API server's ClusterIP. Its retries lasted about
  70 seconds; after that the error escalated and the timers stopped. kopf's health endpoint
  only reports that the process is alive, so the kubelet never restarted it.
- **Why "down" was false.** The failed check set the `publicendpoint_up` gauge to 0 in the
  operator's memory, and nothing updated it again. `PublicEndpointDown` fired on a stale
  value. `PublicEndpointCheckStale` was the alert that described the real problem: the
  checker had stopped.

The same mechanism was behind the previous CoreDNS restart on 2026-10-21 (Renovate still
ran every hour then) and the `NodeMemoryMajorPagesFaults` alert on 2026-10-28 (three
manual Renovate runs in a row).

## What changed

- **The node reserves memory and evicts before it starves**
  ([0010](../decisions/0010-node-memory-reservations.md)): 800Mi reserved for k3s, 300Mi
  for the system, eviction below 200Mi available, `GOMEMLIMIT=700MiB` for k3s, and the
  unused desktop turned off. Allocatable went from 4049Mi (all of the RAM) to 2749Mi. Under the same
  pressure, the kubelet now evicts the pod furthest above its memory request, which is
  Renovate, instead of letting the node go NotReady.
- **The operator reaches the API server by IP and retries longer** (publicendpoint-operator
  0.2.2): a login handler replaces `kubernetes.default.svc` with the address in
  `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`, and API calls are retried for
  about nine minutes instead of about one.

I did not change CoreDNS's probes. k3s manages CoreDNS and re-applies its manifest on
every restart, and the probes were a symptom, not the cause.

## Lessons

- A manual Renovate run right after several rollouts was the trigger. The memory was
  already short; the run only had to add 600Mi. One heavy thing at a time, and not right
  after rollouts.
- Defaults are not safe settings. k3s's eviction covers disk only, and I had assumed the
  kubelet would protect the node. `kubectl get --raw /api/v1/nodes/<node>/proxy/configz`
  shows what the kubelet actually uses.
- A monitor needs an alert about itself. `PublicEndpointCheckStale` existed because a
  checker that stops looks the same as one that sees everything fine, or, as here,
  everything broken.
- The only alert about the NotReady node was a side effect: `ContainerRestarted` on
  CoreDNS. The default node and memory alerts wait 15 minutes, longer than this lasted.
- Save the evidence before restarting. The operator's log was lost the moment the pod was
  deleted; the saved copy is what showed the DNS name and the nine attempts.
