# Node disk filled by unpinned Renovate images

- Date: 2026-10-22
- Impact: none to running services. Node disk usage reached 80% and was rising by several
  GB per day.

## What happened

The cluster status page showed node disk usage at 80.7%. Two days earlier it was 74%. The
node has a 117 GB disk; 90 GB was in use.

The investigation, in order:

- PersistentVolumeClaims: about 7 MB in total. Not the cause.
- Prometheus database (emptyDir): 3.4 GB. Too small to explain the growth.
- containerd image store: 79 GB.

`crictl images` showed many untagged copies of `renovate/renovate`, about 430 MB each
(compressed size), none of them used by a running container.

## Why

- The Renovate CronJob used `renovate/renovate:latest` and ran every hour.
- With the `latest` tag, Kubernetes defaults `imagePullPolicy` to `Always`, so every run
  checked the registry and pulled a new image whenever one was published.
- Renovate publishes several releases a day. Each new pull moved the `latest` tag and left
  the previous image untagged on the node.
- The kubelet removes unused images only when disk usage passes 85%. Below that, nothing
  cleaned them up.

## What changed

- Removed unused images with `crictl --timeout 10m rmi --prune`. Disk usage dropped from
  90 GB to 68 GB (80% to 61%). The first attempt used the default client timeout of two
  seconds and reported errors, but containerd kept deleting in the background.
- Pinned the image to an exact version. A pinned tag defaults to `IfNotPresent`, so hourly
  runs reuse the image already on the node.
- Added a Renovate rule that proposes updates to its own image once a week. The image on
  the node now changes only when such an update is merged.

## Lessons

- `latest` on a frequently scheduled workload is a disk leak, not only a reproducibility
  problem.
- Disk usage was visible on the status page but nothing alerted on it. The growth was
  noticed by looking, not by a signal.
- Measuring before acting mattered: the first suspect, Prometheus, accounted for under 4%
  of the used space.
