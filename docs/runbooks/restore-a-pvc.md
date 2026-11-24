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

## Restore without the cluster

Use this when the Pi or the cluster is gone, or to prove that the backups don't depend on
them. Everything runs on the laptop, and nothing touches the cluster. The restored files
land in `/dev/shm` (RAM, gone at the next reboot), because `rsa_key.pem` comes out
unencrypted. `--no-cache` keeps restic from leaving a cache in `~/.cache/restic`.

Tested on 2026-11-24 for Vaultwarden. It took about 25 minutes, most of it spent working
out the repository URL, which the outside copy didn't hold yet. With the URL at hand it is a
5-minute job.

You need, all from the copy kept outside the laptop and the cluster: the R2 access key ID
and secret key, the restic password, and the full repository URL
(`s3:https://<account-id>.eu.r2.cloudflarestorage.com/pi-cluster-backups/vaultwarden`).

1. Install the tools and check the version (the repository is format 2, which restic 0.14
   and newer can read):

   ```
   sudo pacman -S --needed restic sqlite
   restic version
   ```

2. Open a new terminal tab, so the variables die with it. Enter the values; nothing is shown
   and nothing goes into the shell history. Check them by length only, none may be `0`:

   ```
   read -rsp "AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID; echo
   read -rsp "AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY; echo
   read -rsp "RESTIC_REPOSITORY: " RESTIC_REPOSITORY; echo
   read -rsp "RESTIC_PASSWORD: " RESTIC_PASSWORD; echo
   export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_REPOSITORY RESTIC_PASSWORD AWS_DEFAULT_REGION=auto
   echo "${#AWS_ACCESS_KEY_ID} ${#AWS_SECRET_ACCESS_KEY} ${#RESTIC_REPOSITORY} ${#RESTIC_PASSWORD}"
   ```

3. List the snapshots. Check: the newest one is from 03:30 today.

   ```
   restic --no-cache snapshots --host veneticapi
   ```

4. Restore the newest snapshot. The backup job stages the files in `/stage`, so that is the
   folder to take from the snapshot. Check: `db.sqlite3` and `rsa_key.pem` are there, with no
   `-wal` or `-shm` files and no `tmp/`.

   ```
   restic --no-cache restore latest:/stage --host veneticapi --tag vaultwarden --target /dev/shm/vw-restore
   ls -la /dev/shm/vw-restore
   ```

5. Check the database. Check: `ok`, then the expected number of users and items and a
   recent newest change.

   ```
   sqlite3 /dev/shm/vw-restore/db.sqlite3 'PRAGMA integrity_check;'
   sqlite3 /dev/shm/vw-restore/db.sqlite3 'SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM ciphers), (SELECT max(updated_at) FROM ciphers);'
   ```

6. Check the repository. Check: `no errors were found`.

   ```
   restic --no-cache check
   ```

7. Clean up, then close the tab:

   ```
   shred -u /dev/shm/vw-restore/* && rmdir /dev/shm/vw-restore
   unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_REPOSITORY RESTIC_PASSWORD AWS_DEFAULT_REGION
   ```

What the repository URL errors mean (I hit all of them on 2026-11-24):

- `parsing repository location failed: invalid backend`: the `s3:` prefix is missing.
- `does not follow ip address or domain name standards`: the host part is broken, for
  example `https://` twice or a pasted space.
- `tls: handshake failure`: Cloudflare doesn't know the host name, usually because the ID in
  it is not the account ID. The R2 access key ID is also 32 hex characters. The account ID is
  the part after `dash.cloudflare.com/` in the dashboard's address bar.
- `repository does not exist ... The specified key does not exist`: R2 answered, but there is
  no repository at that path. The bucket is in the EU jurisdiction, so the host needs `.eu.`
  before `r2`; then check the folder name after the bucket.
