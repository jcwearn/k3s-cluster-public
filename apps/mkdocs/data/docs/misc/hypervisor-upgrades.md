# Hypervisor Upgrades

How the Proxmox hosts and their k3s guests get their weekly `apt` upgrades **and their reboots**,
one host at a time, without a human in the loop — and what to do when the run stops.

## Why it exists

The old `ansible-update-linux` job ran `apt dist-upgrade` across all six hosts at once and never
rebooted anything. Kernel updates therefore accumulated as "reboot required" in a weekly email, and
on the hypervisors they were not even flagged: the playbook looked for `/var/run/reboot-required`,
which Ubuntu writes and Debian/PVE never does. Each host sat on a stale kernel until someone found
the time to run the drain → `qm shutdown` → reboot → `qm start` → uncordon sequence from
[Reclaiming Guest Disk Space](reclaiming-guest-disk.md) by hand.

The replacement is the [system-upgrade-controller](../infrastructure/system-upgrade-controller.md)'s
shape, applied to the layer beneath it.

## The flow

```
CronJob (one per host, Sat 03:10 / 05:40 / 08:10, pve-03 → 02 → 01)
  │
  ├─ silence   Alertmanager: this host's id, this VM's id, this node, TargetDown (2 h expiry)
  ├─ gate      all nodes Ready+schedulable · no Pending/Unknown pod · every Running pod Ready
  │            no sibling upgrade Job active · pvecm quorate · VM running
  │            k3s-pre-shutdown.service enabled on the guest        ── any miss: ABORT
  ├─ apt       guest: dist-upgrade, autoremove, /var/run/reboot-required
  │            host:  dist-upgrade, autoremove, running kernel vs newest -pve kernel (+ needrestart)
  ├─ decide    host_reboot  = host wants one
  │            guest_reboot = guest wants one, or host_reboot
  │            neither → skip straight to the report; nothing is cordoned
  ├─ drain     k3s etcd-snapshot save · kubectl drain · verify only DaemonSet pods remain
  ├─ reboot    host path:  qm shutdown (never qm stop) → reboot host → pvecm quorate, pve services,
  │                        local-lvm active → qm start unless onboot did → wait for SSH
  │            guest path: reboot the VM
  ├─ return    node Ready · /healthz/etcd == ok on every node's own IP · uncordon
  │            every pod Ready · soak 10 min · final whole-cluster check
  └─ always    expire the silences · post the summary to ntfy · exit non-zero if anything failed
```

The playbook is `apps/ansible/data/playbooks/upgrade-hypervisor.yml`; the inventory carries the
host → `vmid` / `guest` / `k3s_node` mapping it follows.

## Three design points worth knowing

**The runner is inside the cluster it reboots.** Each CronJob's pod is pinned by node affinity off
the k3s node whose VM it is about to shut down. That is why there are three CronJobs rather than
one loop, and why the same Job can never handle all three hosts.

**The gate aborts; it does not wait.** Two waiting Jobs would both see the cluster come healthy at
the same moment and start together, and two hypervisors down is an outage, not an inconvenience.
The "no sibling Job active" check is the lock between them; the schedule spacing is only the
order. A run that aborts at the gate is a failed Job — `KubeJobFailed` fires and the ntfy summary
says which check tripped. The skipped host waits a week.

**A failure after the drain leaves the node cordoned.** Deliberately, as the controller does: it
stops the roll and is the visible sign a human owes the run a look. The one thing the rescue path
does put back is the VM, if the host is reachable and left it stopped — etcd at 3/3 while you read
the report costs nothing. `KubeNodeCordonedTooLong` fires after two hours if nobody has.

## Reading the ntfy summary

One message per host on the `hypervisor-upgrades` topic. Title `proxmox-03: OK, rebooted host` /
`OK, packages only` / `DRY RUN` / `FAILED`. The body lists packages upgraded on each side, whether
each wanted a reboot and why (the host reason is the kernel pair), what was rebooted, and the
duration of each phase. Failure adds the task name and the error, at `high` priority.

## Time budget

Measured on the first full run (pve-02, 89 host + 9 guest packages, host kernel reboot):

| Phase | Measured | Bounded by |
|---|---|---|
| gate | 8 s | 3 × 20 s retries on pod churn only |
| apt, both sides | 1m17s | SSH keepalive |
| drain + verify | 1m08s | `drain_timeout` 15 min, one retry |
| qm shutdown → host reboot → services → SSH | 1m26s | 6 min stopped-wait, 15 min reboot, 2 min checks |
| Ready → etcd → uncordon → pods settle | 26 s | 10 + 2 + 10 min |
| soak | 10 min | fixed |
| **total** | **14 min** | `activeDeadlineSeconds` 2 h; silence expires at 2 h |

A quiet week -- nothing to install, kernel already current -- exits after the apt step in about
20 seconds without cordoning anything.

A deadline kill skips the `always:` block, so the summary is lost and the silences are left to
expire on their own — that is why they are created with an expiry rather than relying on the
DELETE. `KubeJobFailed` still fires.

## Running one by hand

On the LAN. Never over Tailscale: draining the node that carries the Tailscale connector severs
the path you are watching from.

```bash
kubectl -n ansible create job upg-03-$(date +%s) --from=cronjob/ansible-upgrade-hypervisor-03
kubectl -n ansible logs -f job/upg-03-<ts>
```

Extra vars go into the Job's args:

```bash
kubectl -n ansible create job upg-03-dry --from=cronjob/ansible-upgrade-hypervisor-03 \
  --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].args += ["-e", "dry_run=true"]' \
  | kubectl apply -f -
```

| Var | Effect |
|---|---|
| `dry_run=true` | apt in check mode, no silence, no drain, no reboot. Proves SSH, the gate, the reboot decision and ntfy delivery. |
| `force_reboot=host` | Full path regardless of packages: drain, `qm shutdown`, host reboot, `qm start`. |
| `force_reboot=guest` | Guest-only path: drain, reboot the VM, uncordon. |

Watch from a second terminal:

```bash
watch 'kubectl get nodes; kubectl get pods -A -o wide | grep -vE "Running|Completed"'
```

and on a *different* hypervisor, `watch pvecm status`. The Alertmanager UI's Silences tab should
show three appear at the start and vanish at the end.

## When it stops

1. **Read the ntfy message**, then the Job log: `kubectl -n ansible logs job/<name>`. The failed
   task name tells you which phase.
2. **Gate abort** — nothing was touched. Fix whatever the gate saw (a Pending pod, a cordoned node,
   a missing `k3s-pre-shutdown.service`) and re-run by hand, or let next Saturday take it.
3. **Failed during or after the drain** — the node is cordoned. Check the VM is running
   (`qm status <vmid>` on the host), that k3s is up on it, that `/healthz/etcd` answers `ok` on all
   three node IPs, and only then `kubectl uncordon k3s-0N`. Drain is idempotent; re-running the Job
   is safe once the cause is understood.
4. **Failed with the VM stopped and the host unreachable** — the host did not come back from its
   reboot. There is no IPMI; this is a trip to the machine. The other two hosts hold quorum and
   the cluster is running on two nodes until it returns.
5. **Silences**: expire on their own at two hours. If the run died hard and you are working on the
   host for longer, extend one in the Alertmanager UI rather than living with the pages.

## What it will not do

- Prune old kernels on the hypervisors. `autoremove` is safe there only because every kernel is
  manually marked; see [Proxmox Kernel Maintenance](proxmox-kernel-maintenance.md) before changing
  that.
- Cross a Proxmox major. That stays a hand-run plan (`docs/plans/proxmox-8-to-9-upgrade.md` in
  the repo) with the three CronJobs suspended for the duration, as the 8 → 9 upgrade did.
  [EOL monitoring](../infrastructure/eol-monitoring.md) is what should prompt it.
- Install the shutdown guard. A guest without `k3s-pre-shutdown.service` has been rebuilt and the
  gate refuses it; run `ansible-configure-k3s-shutdown` first.
- Wait for a sibling. See above.
