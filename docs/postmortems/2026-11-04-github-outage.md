# Flux could not fetch from GitHub during a GitHub outage

- Date: 2026-11-04
- Impact: none to running services. For about 70 minutes, no change from the repository
  could reach the cluster.

## What happened

All times are Amsterdam time (UTC+1).

- About 10:44: the GitRepository `flux-system/flux-system` stopped being Ready.
  source-controller could no longer fetch this repository from GitHub.
- 10:49: GitHub posted an incident on its status page, "Incident with Pull Requests, Git
  Operations and Issues", with intermittent failures.
- 10:59: the `FluxResourceNotReady` alert arrived in Telegram, after the 15 minutes the
  rule waits before firing.
- About 11:55: the GitRepository was Ready again.
- About 11:59: the RESOLVED message arrived.

I checked in this order: GitHub's status page (an open incident with Git operations), then
whether the node itself had internet access (the public status page loaded, and it is
served through a Cloudflare tunnel from the node). Both pointed at GitHub, not at the
cluster, so I waited. I did not look at source-controller's logs or the GitRepository's
condition message during the outage; the cause is taken from GitHub's status page and the
matching times.

## Why

- Flux has one Git source: this repository on GitHub, fetched over SSH every minute. Every
  Kustomization in `clusters/staging` depends on it.
- While GitHub's Git operations failed, source-controller could not fetch, and marked the
  GitRepository not Ready.
- Flux keeps applying the last revision it fetched. Nothing new was applied, and nothing
  was removed or rolled back.
- Running pods do not talk to GitHub. All images use pinned tags, so they are pulled only
  when missing from the node (`imagePullPolicy: IfNotPresent`), and a restarted pod starts
  from the cached image.

## What changed

Nothing in the cluster. The outage resolved on its own, and Flux picked up again at its
next fetch.

I considered a second Git source, so the cluster would not depend on one external
service, and decided against it for now:

- A Forgejo mirror as a fallback source would live inside the same cluster. During a
  rebuild, when a source matters most, Forgejo itself comes from Git.
- A second external host, or Flux OCI artifacts in a registry, would move the dependency
  somewhere else and add something to keep in sync, for a failure that did not affect
  running apps.

## Lessons

- A Git source outage freezes changes, not running apps. While the GitRepository is not
  Ready, I do not merge anything; once it recovers,
  `flux reconcile source git flux-system -n flux-system` forces a fetch.
- The Flux alert ([0006](../decisions/0006-flux-alerts-kube-state-metrics.md)) did its
  job on its first real firing: FIRING and RESOLVED both arrived. Unlike the two incidents
  on 2026-10-22, this one was found by an alert, not by looking.
- GitHub is more than the Git source here. A rebuild from scratch needs GitHub and
  `ghcr.io`: Flux bootstrap, this repository, and the images of cluster-status, the
  PublicEndpoint operator and audiobookshelf all come from there. If the node lost its
  cached images during an outage (for example after an image prune), those apps could not
  start until `ghcr.io` was back.
