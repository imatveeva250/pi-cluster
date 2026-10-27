# 0006: Flux resource alerts through kube-state-metrics

## Status

Accepted (2026-10-27)

## Context

Flux reconciles everything in this cluster. When a Kustomization or HelmRelease stops being Ready, changes in Git silently stop reaching the cluster, or a release stays half-upgraded. Prometheus had no Flux metrics: nothing scraped the Flux controllers, and current Flux versions no longer export a reconcile condition metric.

## Decision

kube-state-metrics, which already runs as part of kube-prometheus-stack, reads the `Ready` condition of Flux objects and exports it as `gotk_resource_info`, with labels for the kind, name, namespace, readiness and suspension. A PrometheusRule, `FluxResourceNotReady`, fires when an object that is not suspended has not been Ready for 15 minutes. That covers both `False` and `Unknown`, so a reconcile stuck in progress is caught as well as a failed one.

- The configuration covers Kustomizations, HelmReleases and GitRepositories.
- It lives in its own values file, `kube-state-metrics-flux.yaml`. kustomize turns it into a ConfigMap, and the HelmRelease reads it through `valuesFrom`, so `release.yaml` stays about the chart. A YAML anchor defines the metric once for all kinds. kustomize adds a content hash to the ConfigMap name, and `kustomizeconfig.yaml` updates the reference in the HelmRelease, so every change triggers a Helm upgrade.
- kube-state-metrics keeps its default collectors. Flux's own example runs it in `custom-resource-state-only` mode, which would remove the core metrics that most alert rules here depend on.

## Consequences

- Flux problems reach the phone through the same pipeline as every other alert, with repeats while they last and a resolved message when they end.
- kube-state-metrics needs read access (`list`, `watch`) to the Flux CRDs, added through `rbac.extraRules`.
- HelmRepositories are not covered: kube-state-metrics accepted the configuration for them but exported no series, and the cause was not found. A broken chart repository therefore goes unnoticed until the next chart upgrade fails, which then makes the HelmRelease not Ready.
- The alternative was Flux's notification-controller with a Telegram provider. It is simpler, but sends one message per failure event, with no repeat and no resolved message, and it would be a second alerting path next to Alertmanager.
