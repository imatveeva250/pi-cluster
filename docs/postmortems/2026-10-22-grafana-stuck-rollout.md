# Grafana rollout stuck for 71 days on a missing Secret key

- Date: 2026-10-22 (problem existed since 2026-08-12)
- Impact: no visible outage. Grafana kept running, but on its old configuration: the admin
  login from the SOPS-encrypted Secret was never in effect, and a password set by hand
  lived only in a temporary volume.

## What happened

An inventory of containers without memory limits listed two Grafana pods from two
different ReplicaSets of the same Deployment:

- the old pod, `Running`, 71 days old
- a newer pod, `CreateContainerConfigError`, also 71 days old

The kubelet had retried the newer pod 471,636 times over 71 days. Its events gave the
reason:

    couldn't find key admin-user in Secret monitoring/grafana-secret

## Why

- On 12 August the kube-prometheus-stack HelmRelease was changed to read Grafana's admin
  login from an existing Secret: `admin.existingSecret: grafana-secret` and
  `admin.passwordKey: admin-password`.
- The Secret contained only `admin-password`.
- The values did not set `admin.userKey`, so the chart used its default, `admin-user`, a
  key the Secret did not have.
- A container whose environment refers to a missing Secret key cannot start. The new pod
  stayed in `CreateContainerConfigError`.
- With a rolling update, the old ReplicaSet is scaled down only after the new pod becomes
  ready. It never did, so the old pod, without the Secret, kept serving.
- The usual check after a change was the Flux Kustomization status, which reported
  `Ready`. The Kustomization only applies the HelmRelease; it says nothing about whether
  the workloads inside the release are healthy. Nothing alerted on the stuck rollout.

A side effect: the admin password changed in October with `grafana cli` inside the
running pod applied only to that old pod. Its database is a temporary volume (emptyDir),
so that change would have been lost on any restart.

## What changed

- Added `admin-user` to the SOPS-encrypted Secret.
- Set `admin.userKey: admin-user` explicitly in the HelmRelease values, instead of relying
  on the chart default.
- The kubelet's next retry started the same pod. The rollout completed and the old
  ReplicaSet was scaled down.
- The Helm upgrade for the values change had failed early, because the Grafana Deployment
  was still marked as failed when the upgrade checked it. After the rollout completed,
  `flux reconcile helmrelease kube-prometheus-stack --force` ran the upgrade again, and
  it succeeded.
- Login with the credentials from the Secret confirmed the fix.

## Lessons

- A running service is not proof that the current configuration is applied. A failed
  rollout can leave the previous version serving indefinitely.
- A healthy Flux Kustomization does not mean healthy workloads; check the HelmRelease and
  the Deployment itself.
- Chart defaults are invisible in the repository. Keys that must match a Secret are set
  explicitly.
- As in the Renovate image incident on the same day, the problem was found by looking,
  not by an alert.
