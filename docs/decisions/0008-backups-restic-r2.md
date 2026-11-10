# 0008: Backups with restic to Cloudflare R2

## Status

Accepted (2026-11-10)

## Context

Three apps keep state on PVCs: Vaultwarden, Forgejo and audiobookshelf. All three use SQLite. The PVCs are k3s `local-path` volumes with reclaim policy `Delete`, so deleting a PVC removes its directory on the node immediately. The node has one disk and no second one to copy to. A deleted PVC, a dead disk or a lost Pi would each have meant losing the data.

The data is small: on 2026-11-09 the three PVCs used about 6.4 MB together (Vaultwarden 376K, Forgejo 5.5M, audiobookshelf 556K).

SQLite in WAL mode writes changes to `db.sqlite3-wal` first and copies them into the main file only at a checkpoint. On 2026-11-09 Vaultwarden's main file had last been written on 2026-10-27; every change after that existed only in the WAL. A copy of `db.sqlite3` alone would have been a valid, but two weeks old, database. Copying all three files while the app runs can catch the WAL in the middle of a write.

## Decision

Each app with data gets a CronJob in its own namespace that runs restic and sends encrypted snapshots to a Cloudflare R2 bucket.

- **restic in a plain CronJob.** restic encrypts before upload, deduplicates, keeps snapshots and can verify the repository (`restic check`). A CronJob uses no memory between runs. The pod mounts the app's PVC; it has to run in the app's namespace because a PVC can only be mounted from its own namespace.
- **A consistent database copy first.** The job runs `sqlite3 db.sqlite3 ".backup ..."` into an `emptyDir`, checks the copy with `PRAGMA integrity_check`, copies the remaining files (for Vaultwarden `rsa_key.pem`, without `tmp/`), and only then runs `restic backup` on that directory. The `.backup` command reads the database as the app sees it, WAL included, inside one read transaction.
- **Own image, [`pvc-backup`](https://github.com/imatveeva250/pvc-backup).** The restic binary from the official image, on a pinned Alpine base with `sqlite`, `curl` and `tar`, plus the backup script. Built by GitHub Actions on version tags; Renovate tracks both base images.
- **Off-site only.** One R2 bucket, `pi-cluster-backups`, in the EU jurisdiction, with one restic repository per app (`.../vaultwarden`). The R2 token can read and write objects in that bucket only. A copy on the same disk would protect only against a deleted PVC, not against losing the disk or the Pi.
- **Retention and checks.** Daily at 03:30 Europe/Amsterdam (away from Renovate's runs), keep 7 daily, 4 weekly and 6 monthly snapshots, prune in every run, full `restic check --read-data` once a week. The host is fixed to `veneticapi`; otherwise every pod name would count as a new host and `forget` would never delete anything.
- **Two ways to notice a problem.** A failed Job fires the existing `KubeJobFailed`. A Job that never runs produces no failed Job, so every run also pings a healthchecks.io check (start, success or exit code), which alerts when the daily ping is missing.
- **Hardened pod.** Runs as the UID that owns the app's files (1000 for Vaultwarden), `runAsNonRoot`, read-only root filesystem, no capabilities, `RuntimeDefault` seccomp. `activeDeadlineSeconds` kills a hung run, so `concurrencyPolicy: Forbid` can't block later runs forever.
- **Credentials.** The R2 keys, the repository URL (it contains the account ID), the restic password and the ping URL are a SOPS-encrypted Secret per app. The restic password and the age key that decrypts SOPS are also kept outside the laptop and the cluster: a backup can't depend on the vault it restores.
- **Not backed up: Prometheus and Alertmanager.** Prometheus holds 10 days of metrics (3.3G), which are history, not state; dashboards and rules are in Git. Alertmanager only keeps silences and its notification log.

## Consequences

- The restore is tested. On 2026-11-10 a throwaway pod restored the latest snapshot into an `emptyDir`: users, items and the newest change matched the live database, including a change that existed only in the WAL. The same night Vaultwarden's PVC was deleted and restored from the 03:30 snapshot, with all items present. The steps are in [docs/runbooks/restore-a-pvc.md](../runbooks/restore-a-pvc.md).
- A restore needs about 5 minutes of downtime and Flux suspended, so it doesn't recreate an empty PVC halfway through. The first attempt showed what happens otherwise: Vaultwarden started on an empty volume and created a new database and a new `rsa_key.pem`.
- Forgejo and audiobookshelf are not backed up. Forgejo has no repositories, and audiobookshelf has an empty library; losing either means setting up a fresh instance from Git, not losing data. Each gets a backup the moment it holds something worth keeping: Forgejo's first repository, or a real library with listening progress in audiobookshelf.
- Completed backup pods keep a reference to the PVC, so a PVC can't be deleted until those pods are gone (part of the runbook).
- The R2 token can delete objects, because `prune` needs that. Someone with the token could delete the backups. R2 bucket lock rules could prevent this; not set up.
- A restore depends on R2, `ghcr.io` (the image) and the secrets in Git. Without the restic password, the snapshots can't be read.
- A new restic or Alpine version means a new `pvc-backup` tag and a tag change in each CronJob.
- Alternatives considered:
  - Velero and k8up both run a controller all the time; on a 4 GB node that is memory spent every hour to back up a few megabytes once a day.
  - rclone sync keeps one copy, so a corrupted database would overwrite the last good one.
  - Copying the files with `tar` while the app runs risks an inconsistent or old database (see Context).
