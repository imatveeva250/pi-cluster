# Patch the node

Use this to install the operating system updates on the Pi (Raspberry Pi OS, which is Debian
trixie): security fixes, a new kernel, new firmware. On a single node, the reboot at the end
takes the whole cluster down for a few minutes. Pods come back by themselves, because their
desired state is in the API server and in Git, and their data is on PVCs.

k3s is not an apt package (it was installed with its install script), so this does not
change the Kubernetes version. Upgrading k3s is a separate task.

Tested on 2026-11-17: 379 packages after 145 days without a reboot, kernel 6.18.34 to
6.18.60, openssl 3.5.6 to 3.5.9. The upgrade took about 6 minutes; the cluster was back and
both public sites answered within a few minutes of the reboot.

## Before you start

- Two terminals: one SSH session on the Pi, one shell on the laptop. Check the prompt before
  every command: node commands on the laptop do nothing useful, or the wrong thing.
- If you are connected to the Pi over Tailscale (`echo $SSH_CONNECTION` shows a `100.x`
  address), the upgrade of the `tailscale` package restarts `tailscaled` and drops the SSH
  session in the middle of apt. Run the upgrade inside `tmux` (step 4), so it keeps going.
- Pick a quiet moment: not right before the 03:30 backup, not on a Renovate slot (00, 06, 12,
  18 UTC), and not while something else is rolling out.

## Steps

After every step there is a check. Don't go on until the check passes.

### 1. Look at what will change (Pi)

```bash
uptime
df -h /
apt-mark showhold
sudo apt update
apt list --upgradable 2>/dev/null | grep -cv '^Listing'
apt list --upgradable 2>/dev/null | grep -E '^(linux-image|raspi-firmware|raspberrypi|openssl|libssl|systemd|openssh|tailscale|containerd|iptables|nftables)'
```

Check: a few GB free, no held packages. The filtered list shows what matters for the node:
the kernel and firmware need the reboot, openssl needs its users restarted (the reboot does
that too), and `iptables`/`nftables` are what k3s uses for Service routing, so a change there
is worth reading about first.

### 2. Check the latest backup (laptop)

```bash
kubectl get jobs -n vaultwarden
```

Check: the newest `vaultwarden-backup-...` Job is `Complete`. Everything with state is in R2
before the node is touched.

### 3. Silence the alerts (laptop)

The reboot makes targets disappear for a few minutes. Silence every alert except `Watchdog`,
which has to keep pinging healthchecks.io. The silence is kept on Alertmanager's PVC, so it
survives the reboot.

```bash
kubectl exec -n monitoring sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
  amtool silence add 'alertname!=Watchdog' --duration=1h --comment="node patching" --author=venetica \
  --alertmanager.url=http://localhost:9093
```

Check: it prints a silence ID. Also save the pod list to compare with later:

```bash
kubectl get pods -A > ~/pods-before-patching.txt; grep -vc Completed ~/pods-before-patching.txt
```

### 4. Upgrade (Pi, inside tmux)

```bash
TERM=xterm-256color tmux new -s patch
sudo apt full-upgrade
```

`TERM=xterm-256color` is needed when connecting from kitty (the Pi doesn't know
`xterm-kitty`). `full-upgrade`, not `upgrade`: a new kernel version is a new package, and
plain `upgrade` never installs new packages, so it would hold the kernel back.

Check before answering `Y`: read the "to remove" line. On 2026-11-17 it removed
`libcamera0.7` (replaced by a newer version) and `pcmanfm` (the desktop's file manager), both
unused on this node. A removal that touches k3s, containerd, networking or ssh: answer `n`.

If the SSH session freezes when `tailscale` is upgraded: wait half a minute, connect again,
and reattach with `TERM=xterm-256color tmux attach -t patch`. Detach with `Ctrl+b`, then `d`.

### 5. Check the upgrade (Pi)

```bash
apt list --upgradable 2>/dev/null | grep -cv '^Listing'
sudo dpkg --audit
uname -r
dpkg -l 'linux-image-rpi*' | grep ^ii
```

Check: `0` upgradable, `dpkg --audit` prints nothing (no half-configured packages). If the
running kernel (`uname -r`) is older than the installed one, the reboot is needed.
Raspberry Pi OS does not create `/var/run/reboot-required` (that file comes from an Ubuntu
helper), so its absence means nothing here.

`tail -n 30 /var/log/apt/history.log` shows what the run installed and removed.

### 6. Reboot (Pi)

If `/etc/rancher/k3s/config.yaml` needs a change, make it now (backup first, then
`sudo diff` against the backup), so the reboot picks it up. Then:

```bash
sudo reboot
```

Wait about 3 minutes. Until k3s is up, `kubectl` answers with `connection refused` or
`TLS handshake timeout`.

### 7. Check the node (Pi)

```bash
uname -r
systemctl is-active k3s
sudo journalctl -u k3s -b --no-pager | grep -iE 'level=(error|fatal)' | tail -5
free -m
```

Check: the new kernel, `active`. A few errors from the first seconds are normal: on
2026-11-17 the API server got `no route to host` for metrics-server (`10.42.0.6:10250`) before
the pod network was up. A `fatal` means k3s did not start: restore the `config.yaml` backup.

### 8. Check the cluster (laptop)

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl get pods -A | grep -vc Completed
flux get kustomizations; flux get helmreleases -A
for h in abspi status; do curl -sS -o /dev/null -w "$h %{http_code}\n" --max-time 10 https://$h.matveeva.dev; done
```

Check: the node is `Ready` with the new kernel in `KERNEL-VERSION`; no pod outside Running or
Completed (pods still starting a minute after boot are fine, run it again); the same pod count
as in step 3; all Kustomizations and HelmReleases `True`; both sites `200`.

### 9. Deal with the restart alerts (laptop)

A reboot restarts every container: each pod keeps its name and age, and its restart count goes
up by one. `ContainerRestarted` looks at restarts over the last hour, so it would fire for
every pod for an hour after the reboot, longer than the first silence lasts. Silence that one
alert for a bit more than an hour:

```bash
kubectl exec -n monitoring sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
  amtool silence add alertname=ContainerRestarted --duration=75m --comment="restarts from node reboot" --author=venetica \
  --alertmanager.url=http://localhost:9093
```

Before that, check what is firing. `amtool alert query` hides silenced alerts; add `--silenced`
to see them too. Anything other than `Watchdog` and `ContainerRestarted` needs a look.

Then let both silences run out by themselves.

## Afterwards

- The `tmux` session ended with the reboot. `tmux` stays installed for next time.
- Note the date, the kernel and the number of packages here or in the commit message.
