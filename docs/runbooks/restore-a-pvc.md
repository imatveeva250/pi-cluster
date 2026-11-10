# Restore a PVC from backup

Use this when an app's PVC is gone or its data is broken: the PVC was deleted (local-path
removes the directory right away, there is no recycle bin), the database is corrupt, or a
bad change has to be undone. Backups are restic snapshots in Cloudflare R2, made every night
at 03:30 by a CronJob in the app's namespace ([0008](../decisions/0008-backups-restic-r2.md)).

Written for Vaultwarden, which is the app I have restored so far. The same steps work for
another app with its own CronJob and Secret; change the names, the UID and the database file.

Tested on 2026-11-10. The restore itself took about 5 minutes. My first attempt that night
went wrong (see "What went wrong the first time"), and Vaultwarden ran for a few minutes on
an empty database before I noticed.

## Before you start

- Work from the root of this repository and keep an eye on the prompt. Two of the commands
  below use paths relative to the repo; run from anywhere else, they fail.
- Don't use the app between the last backup and the restore. Anything changed after the
  snapshot is lost.
- The restore pod is [`vaultwarden-restore-pod.yaml`](vaultwarden-restore-pod.yaml), in this
  folder. It is not part of any Flux Kustomization, so Flux never applies it.

## Steps

After every step there is a check. Don't go on until the check passes. Step 7 is the one
that can turn a mistake into an empty app, so it has three checks in front of it.

### 1. Check the latest backup

```bash
kubectl get jobs -n vaultwarden
```

The newest `vaultwarden-backup-...` Job is `Complete`, and the healthchecks.io check
`veneticapi-backup-vaultwarden` is green. If the last backup failed, find out why before
deleting anything.

### 2. Suspend Flux for the apps

```bash
flux suspend kustomization apps
flux get kustomizations apps
```

Check: `SUSPENDED` is `True`.

Otherwise Flux undoes the manual steps: it scales the app back up, and once the PVC is gone
it creates a new empty one and starts the app on it.

### 3. Stop the app

```bash
kubectl scale deployment vaultwarden -n vaultwarden --replicas=0
kubectl get pods -n vaultwarden
```

Check: no `vaultwarden-...` pod left. Also delete the completed backup pods
(`vaultwarden-backup-...`), using their full names. They still reference the PVC, and
Kubernetes keeps the PVC in `Terminating` for as long as any pod references it. Deleting the
pods keeps the Jobs and their history.

```bash
kubectl delete pod <full-pod-name> -n vaultwarden
```

### 4. Delete the PVC (skip if it is already gone)

```bash
kubectl delete pvc vaultwarden-data-pvc -n vaultwarden --wait=false
sleep 15
kubectl get pvc -n vaultwarden
kubectl get pv | grep vaultwarden
```

Check: both commands print nothing. If the PVC hangs in `Terminating`,
`kubectl describe pvc vaultwarden-data-pvc -n vaultwarden` shows under "Used By" which pod
still holds it.

### 5. Recreate the PVC from Git

```bash
kubectl create -f apps/base/vaultwarden/vaultwarden-data-pvc.yaml
kubectl get pvc -n vaultwarden
```

Check: the PVC exists and is `Pending`. That is normal: local-path creates the volume only
when the first pod uses it. `create` instead of `apply` leaves no `last-applied`
annotation behind; Flux takes the PVC over when it is resumed.

### 6. Restore

```bash
kubectl get deployment vaultwarden -n vaultwarden
```

Check: `READY` is `0/0`. Then:

```bash
kubectl apply -f docs/runbooks/vaultwarden-restore-pod.yaml
sleep 10
kubectl logs -n vaultwarden vaultwarden-restore -f
```

Check, all of these:

- the listing before the restore is empty
- after the restore, `db.sqlite3` and `rsa_key.pem` are there, owned by `1000`
- `PRAGMA integrity_check` prints `ok`
- the last line shows the expected number of users and items, and a newest change from
  before the backup

```bash
kubectl delete pod vaultwarden-restore -n vaultwarden
```

### 7. Give control back to Flux

Only when all of these are true: the PVC exists, the restore log passed, and the Deployment
is still at `0/0`.

```bash
flux resume kustomization apps
kubectl get pods -n vaultwarden -w
```

Check: a new `vaultwarden-...` pod is `1/1 Running`. Stop watching with Ctrl+C.

### 8. Check that the app started on the restored data

```bash
kubectl exec -n vaultwarden deploy/vaultwarden -- ls -la --time-style=full-iso /data
kubectl logs -n vaultwarden deploy/vaultwarden | grep -i 'rsa_key\|Rocket has launched'
```

Check: `rsa_key.pem` keeps its original date, and the log does **not** say
`Private key 'data/rsa_key.pem' created correctly`. If it does, Vaultwarden started on an
empty volume: go back to step 2.

```bash
flux get kustomizations apps
kubectl get pvc vaultwarden-data-pvc -n vaultwarden -o jsonpath='{.metadata.labels}{"\n"}'
```

Check: `apps` is Ready and not suspended, and the PVC has the
`kustomize.toolkit.fluxcd.io/name: apps` label, so Flux manages it again.

### 9. Log in

Open the web vault and log in with the exact email the account was created with, and check
the items. Clients that talked to the app while it was down may need one new login.


## Check a backup without touching the app

To see that a backup can be restored without stopping anything, run a pod like the one
above with an `emptyDir` as the target instead of the PVC, and compare the restored
database with the live one (users, items, newest change, `rsa_key.pem` hash). I did this
before the drill; it changes nothing.
