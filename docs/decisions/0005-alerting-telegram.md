# 0005: Alert delivery through Telegram

## Status

Accepted (2026-10-23)

## Context

kube-prometheus-stack ships about a hundred alert rules, including ones that cover stuck rollouts, crash loops, failed Jobs and filling disks. Until now Alertmanager had no receiver, so these rules evaluated with nobody to tell. A Grafana rollout stayed stuck on a missing Secret key for 71 days without anyone noticing.

This is a single-person homelab. Alerts need to reach one phone, at no cost, without running anything extra in the cluster.

## Decision

Alertmanager sends alerts to a Telegram bot.

- The bot token is a SOPS-encrypted Secret, `alertmanager-telegram`, mounted into Alertmanager with `alertmanagerSpec.secrets` and read through `bot_token_file`. It never appears in Helm values, so it exists only in the encrypted file in Git and in one Secret in the cluster.
- Alerts are grouped by `alertname` and `namespace`, wait 30 seconds to collect related alerts, and repeat every 4 hours while they last. Resolved alerts are sent too.
- `Watchdog`, which always fires, is sent every minute to a healthchecks.io check as a dead man's switch. If the pings stop for about 10 minutes, healthchecks.io notifies through its own Telegram bot and by email, independent of the cluster. The ping URL is a SOPS-encrypted Secret, `alertmanager-healthchecks`, read through `url_file`. `InfoInhibitor` goes to a `null` receiver.
- The chart's scrape targets for the controller manager, scheduler, proxy and etcd are disabled. k3s runs these inside its own process, so the targets never answer, and their alerts would fire forever.

## Consequences

- Every default rule now reaches the phone. Before the change, the only firing alerts besides Watchdog were the three k3s false positives and a Renovate Job that had failed 66 days earlier.
- A failed Job keeps `KubeJobFailed` firing until the Job is deleted. Deleting it after reading the failure is the acknowledgement.
- Telegram is an external dependency: if it is down, alerts are not delivered. healthchecks.io covers the opposite case: when the cluster, the node or the network fails, the missing Watchdog pings raise an alert from outside. Tested by silencing Watchdog for 15 minutes.
- Alertmanager keeps its notification log and silences in an emptyDir. A pod recreation forgets silences and sends still-active alerts again.
- Slack was the alternative. It needs a workspace, and the phone is the only destination.
