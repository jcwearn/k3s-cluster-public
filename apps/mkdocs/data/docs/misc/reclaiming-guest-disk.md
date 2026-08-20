# Reclaiming Guest Disk Space

How the k3s guests filled 80% of their disks with container images nobody needed, why neither
Kubernetes nor LVM noticed, and the procedure for reclaiming it.

Done once on 2026-08-20, recovering **~1.05 TiB across the three guests** and taking each
hypervisor's thin pool from ~63% to under 10%.

## The two layers

Space has to be released **twice** before it comes back, and the two releases are independent:

```
container image layers          ← released by: crictl rmi --prune
  in the guest filesystem
        │
        │  ext4 marks blocks free
        ▼
guest block device (sda1)        ← released by: fstrim, but ONLY if...
        │
        │  UNMAP / TRIM, requires discard=on on the VM disk
        ▼
LVM-thin volume on the host      ← this is what `lvs` data_percent shows
```

Freeing files in the guest does nothing for the host. Until `discard=on` is set, the thin volume
stays allocated no matter how empty the filesystem gets — which is how these guests reached 99.8%
allocated while genuinely using less than 10%.

## Why the image store grew unchecked

Kubelet garbage-collects images **only under disk pressure**:

| Setting | Value | Meaning |
|---|---|---|
| `imageGCHighThresholdPercent` | 85 | GC starts when the disk is this full |
| `imageGCLowThresholdPercent` | 80 | GC stops once back down to here |
| `imageMaximumGCAge` | `0s` | Age-based eviction — disabled by default |

These nodes sat at 79–83% for the life of the cluster: just under the trigger. GC never ran once.
Even if it had, evicting from 85% to 80% frees about 24 GiB and stops.

Meanwhile Renovate replaces image tags continuously, and every superseded layer stayed. The result,
measured before the cleanup:

| Node | containerd store | images held | images referenced cluster-wide |
|---|---|---|---|
| k3s-01 | 390 GiB | 270 | **73 total, across all three nodes** |
| k3s-02 | 370 GiB | 318 | |
| k3s-03 | 374 GiB | 244 | |

`imageMaximumGCAge` is now set to `168h` by
[`ansible-configure-image-gc`](../apps/ansible.md), so this should not recur.

## Procedure

### 1. Prune the images

Per node, no downtime, nothing user-visible:

```bash
sudo k3s crictl images -q | wc -l          # before
sudo k3s crictl rmi --prune
```

> **Do not judge the result for at least 30 minutes.** `crictl rmi --prune` deletes image *records*
> synchronously — it returns in seconds, and `df` barely moves. containerd's garbage collector then
> removes the unreferenced content and snapshots **asynchronously**, and it is unhurried: on
> 2026-08-20 the three nodes took **6, 12 and 27 minutes** respectively before the space appeared,
> each in one sudden drop. Reading the flat period as failure is the obvious mistake, and it was
> made twice on the day.

Watch it from Prometheus rather than the node, since `du` on a store that size takes minutes itself:

```promql
node_filesystem_avail_bytes{mountpoint="/"}
```

The prune removes any image no container references, including exited ones. Anything not currently
running — a suspended CronJob's image, for instance — is re-pulled on next use. That is a pull, not
an outage.

### 2. Enable `discard=on` (needs a power cycle)

**Check the VM config, not the guest.** This is the trap that hid the problem for months:

```bash
qm config <VMID> | grep scsi0
```

The guests reported `DISC-GRAN 4K, DISC-MAX 1G` in `lsblk -D`, and `fstrim.timer` was enabled and
active, running weekly. Trimming *appeared* to work. It did nothing, because `ssd=1` alone makes
QEMU advertise UNMAP support to the guest while silently dropping the commands — only `discard=on`
passes them through to LVM. **`qm config` is authoritative; `lsblk -D` inside the guest is not.**

`discard` is a QEMU device property, so it needs a full stop/start — a reboot from inside the guest
will not apply it. Set it while the VM is **stopped** to avoid pending-change confusion entirely:

```bash
kubectl drain k3s-0N --ignore-daemonsets --delete-emptydir-data --timeout=600s
# on the hypervisor:
qm shutdown <VMID> --timeout 300
qm status <VMID>                      # MUST read "stopped" before continuing
qm set <VMID> --scsi0 local-lvm:vm-<VMID>-disk-0,size=500G,ssd=1,discard=on
qm config <VMID> | grep scsi0         # confirm BOTH ssd=1 and discard=on
qm start <VMID>
```

Re-state the whole disk string including `size=` — `qm set` replaces the line rather than merging
into it.

### 3. Trim, then uncordon

```bash
sudo fstrim -av                        # takes several minutes; run it detached
```

Keep the node cordoned until the trim finishes, so the filesystem stays quiet. Then:

```bash
kubectl uncordon k3s-0N
```

Watch `data_percent` fall live on the hypervisor while the trim runs:

```bash
lvs -o lv_name,lv_size,data_percent --units g
```

## Draining notes

- **k3s-01 needs `--disable-eviction`.** The four CloudNativePG clusters run at `instances: 1` with
  `minAvailable: 1`, so their PDBs report `allowed=0` and a normal drain hangs forever rather than
  failing. `--disable-eviction` deletes the pods instead of evicting them, bypassing the PDB.
- **Draining a control-plane node can reset API connections.** kube-vip runs as a DaemonSet on all
  three, so the VIP fails over mid-drain and `kubectl drain` reports
  `connection reset by peer` against several pods. It is harmless — re-run the drain and it
  completes.
- The `k3s-pre-shutdown` service from
  [`ansible-configure-k3s-shutdown`](../apps/ansible.md) is what stops the VM hanging on shutdown
  with dirty NFS buffers. It needs to be in place before any of this.

## Results, 2026-08-20

| | guest used before | after | thin pool before | after |
|---|---|---|---|---|
| k3s-01 / pve-01 | 398 G (83%) | 37 G (7.7%) | 63.06% | **6.60%** |
| k3s-02 / pve-02 | 379 G (79%) | 25 G (5.2%) | 62.67% | **5.47%** |
| k3s-03 / pve-03 | 382 G (79%) | 49 G (10.2%) | 63.05% | **8.04%** |

The pool figures drift upward afterwards as workloads reschedule and write real data — that is
expected and is the point. The volumes now track actual usage instead of a high-water mark; a few
hours later the three pools read 6.60 / 9.00 / 9.46%.

This also makes `vzdump` guest backups feasible for the first time; a fully-allocated 500 GiB volume
is why they had to be skipped during the Proxmox VE 8→9 upgrade.

## References

- [Ansible](../apps/ansible.md) — the `configure-image-gc` playbook that bounds the store
- [Proxmox Kernel Maintenance](proxmox-kernel-maintenance.md) — the other host-level maintenance task
- [Kubernetes garbage collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
