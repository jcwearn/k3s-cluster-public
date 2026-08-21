# Upgrading TrueNAS

How to move the NAS at `${LAN_PREFIX}.200` between major TrueNAS releases, why it is done by hand,
and the two things about this particular box that make an otherwise routine upgrade able to lock you
out of it.

Written for **25.04 (Fangtooth) → 25.10.6 (Goldeye)**, but the shape is the same every time.

## Why this is manual

Datasets, NFS exports, snapshot tasks and the scrub schedule live in
[`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra) and change through plan-on-PR.
The OS does not, and the reason is not that nobody got round to it: the `PjSalty/truenas` provider
exposes no resource or data source for `update.*`, `boot.*` or boot environments at all. That is the
correct shape. An OS upgrade is a reboot with a rollback point, and what makes it safe is a person on
the LAN watching the box come back, not a converged plan. The ownership table in that repository has
said so since it was written: *TrueNAS OS updates — nobody — done in the UI, deliberately.*

What the repository does contribute is the before-and-after. A clean `tofu plan` on **both** sides of
the reboot is how you find out that an upgrade quietly rewrote an export permission or an NFS
setting — which is a thing that happens, and which otherwise surfaces as a broken mount three days
later.

## Read this first

Two properties of this box turn a routine upgrade into an outage if you skip them.

### 1. The tailscale app is the access path, and the upgrade restarts it

`truenas.${DOMAIN}` is a CNAME to a MagicDNS name served by **the tailscale app running on the box
being upgraded**. That is the route `truenas-infra`'s CI takes, the route its scripts take, and
probably the route you take.

An upgrade restarts the entire Docker/apps subsystem. If that one app does not come back, the box is
unreachable over the tailnet — and it is not hypothetical: see
[TrueNAS Docker Default Interface Fix](truenas-docker-default-interface.md), which is that exact
failure class already hitting this box on 25.04.

> **Warning**
> Do not run this upgrade remotely. Be on the LAN, reach the box at `${LAN_PREFIX}.200`, and have a
> keyboard and monitor within reach. You cannot upgrade the thing you are reaching the thing
> through.

### 2. The cluster's storage is this box

All three NFS StorageClasses — `truenas-nfs-rwx`, `truenas-nfs-postgres`, `truenas-nfs-monitoring` —
are exports on this NAS. See [TrueNAS](../infrastructure/truenas.md). Every CloudNativePG database
and all of Prometheus' persistence live on them.

The reboot is an NFS outage of several minutes. NFS clients **block on I/O rather than fail
cleanly**, so pods do not crash and reschedule — they hang, and some stay hung after the server
comes back. Step 4 makes that a decision rather than a surprise.

## What 25.10 changes that touches this box

Checked against the live box on 2026-08-21. Almost every breaking change lands on something this
system does not have, which is what makes this upgrade a small one.

| 25.10 change | Applies here? |
|---|---|
| SMART test scheduling removed from the UI; existing schedules migrate to cron tasks | **No.** There are no scheduled SMART tests. `smartd` still runs and still polls; only the UI scheduling is gone |
| Certificate Authority create/sign removed | **No.** No CAs exist; the UI cert is the self-signed `truenas_default` |
| NVIDIA drivers now Turing-and-newer only | **No.** Intel N150, no discrete GPU |
| Active Directory AUTORID IDMAP backend removed | **No.** No directory services configured |
| VMs on the Containers screen no longer autostart | **No.** No VMs and no Incus instances |
| SMB share config shows only preset-relevant options; "No Preset" shares migrate to "Legacy Share" | **Yes** — verify the `backups` share afterwards. The box reports `ENHANCED_TIMEMACHINE` today |
| REST API deprecated; **every call raises an alert from 25.10.1** | **Yes** — `discover.sh` and `check-credentials.sh` still use REST. Expect the alert, and do not dismiss it silently: it is the countdown to 26, which removes REST entirely |
| Update profiles: the old Conservative/Mission Critical pair replaced by **General** and **Early Adopter** | **Yes** — pick General |

## Procedure

### 1. Establish the before-picture

From a checkout of `truenas-infra`:

```bash
sops exec-env secrets.enc.env './scripts/check-credentials.sh'
sops exec-env secrets.enc.env './scripts/tf.sh plan'
sops exec-env secrets.enc.env './scripts/discover.sh'
```

**The plan must be clean.** A plan that already carries a diff makes every post-upgrade diff
unattributable, which throws away the main reason to have the repository during an upgrade at all.
Commit the refreshed `imports/*.json` — that is the before-picture, and the pre-commit hook enforces
the credential redaction.

`tf.sh` defaults to `read_only`, so none of this can change anything.

### 2. Take the backups that survive the box

1. **System → General → Manage Configuration → Download File.** Store it *off* the box. The boot
   pool is on eMMC (`mmcblk0`); this file is the only artifact that survives that device failing,
   not merely a convenience.
2. Confirm the Postgres backups are current — see [Postgres Backups](../infrastructure/postgres-backups.md).
   They ship to R2 and do not depend on this NAS, which is exactly why they are the thing to check.

### 3. Record the rollback target

**System → Boot.** Write down the name of the **active boot environment**, verbatim.

This is the entire rollback plan, and it is one line. Rollback is one reboot if you have the name and
a scavenger hunt if you do not — and the API does not help: `/bootenv` 404s on 25.04's REST API, so
the UI is the only source. Also confirm here that the boot pool has room; anything above a few GB
free is plenty for another boot environment.

Finally, check **System → Alerts** is empty. Starting an upgrade on top of an existing fault means
you cannot tell afterwards which one the upgrade caused.

### 4. Quiesce the cluster

Write down what you are stopping and the exact commands to start it again **before** you stop
anything — the NFS outage is also an outage of anything whose only copy lives on an NFS-backed
volume.

The CloudNativePG clusters are what matter. Each is single-instance on an NFS-backed PVC with no
replica to fail over to, so an unclean stall is the realistic way to lose one:

```bash
for ns in immich n8n paperless-ngx; do
  kubectl -n $ns get cluster
done

# Hibernate each cluster -- a clean shutdown, not a drain
for ns in immich n8n paperless-ngx; do
  kubectl cnpg hibernate on -n $ns "$(kubectl -n $ns get cluster -o name | cut -d/ -f2)"
done
```

Scale down the apps in front of them first so they are not writing into a database that is going
away. Prometheus can be left running — a gap in the TSDB is not a corruption — but expect its pod to
be unhappy for a few minutes after the NAS returns.

Then suspend Renovate. It runs every 30 minutes against an NFS-backed cache on the box you are
about to reboot, and `concurrencyPolicy: Forbid` means a job that hangs on `/cache` blocks every
subsequent tick until its deadline expires — so a single run caught by the outage costs the next
half hour too. Neither pod-health rule would tell you: the general one excludes the namespace, and
the Renovate-specific one does not match `Pending`.

```bash
kubectl -n renovate patch cronjob renovate-bot -p '{"spec":{"suspend":true}}'

# Drop anything already mid-flight
kubectl -n renovate delete job -l batch.kubernetes.io/job-name --field-selector status.successful!=1
```

`suspend` is not declared in `apps/renovate/cronjob.yaml`, so `kustomize-controller` does not own
the field and will not reconcile it back — the patch holds until you undo it in step 6. That also
means nothing will undo it *for* you if you forget, which is what `RenovateStale` is for.

### 5. Upgrade

All in the TrueNAS UI, on the LAN.

1. **System → Update.**
2. Set the **Update Profile** to **General**. 25.10 replaced the old Conservative/Mission Critical
   pair with General and Early Adopter; General is the right one for this box.
3. Select the **TrueNAS-SCALE-Goldeye** train. It is offered alongside Fangtooth already — no manual
   ISO is needed.
4. **Download and install**, then reboot when it asks.

> **Note**
> Target 25.10.6 or later, never 25.10.0 or 25.10.1. 25.10.2 fixed a
> `Could not prepare Boot variable: No space left on device` failure that left some 25.04 → 25.10
> upgrades **unbootable**. It is an EFI NVRAM problem, not a pool-space one, so a healthy boot pool
> is not evidence against it.

The reboot takes several minutes and the box is silent for most of it. The healthchecks.io cron job
that pings every five minutes is a usable liveness signal from outside — if it starts pinging again,
the box booted and cron is running, which is a stronger statement than a ping reply.

### 6. Verify, in this order

The order matters: each step tells you whether the next one is worth attempting.

```bash
# 1. It booted and it is the version you asked for
ssh truenas 'cat /etc/version'

# 2. The API still accepts the key. The 25.04 upgrade revoked legacy API keys;
#    this is how you learn in ten seconds instead of from tomorrow's drift job
sops exec-env secrets.enc.env './scripts/check-credentials.sh'

# 3. Nothing moved underneath the configuration
sops exec-env secrets.enc.env './scripts/tf.sh plan'
```

Step 3 must be clean, or every diff explained before you go further. Watch the SMB share in
particular — 25.10 rewrote the preset vocabulary.

Then, in the UI and the cluster:

- **The `tailscale` app is Running**, and `truenas.${DOMAIN}` resolves and loads. If it does not,
  you are still on the LAN and can fix it; that is the whole reason for the on-LAN rule.
- **Reapply `/etc/netdata/netdata.conf`.** TrueNAS overwrites it on every update and metrics go
  quiet until you do. The procedure is in
  [TrueNAS Monitoring](../infrastructure/truenas-monitoring.md). **This is the step most likely to be
  skipped**, because nothing fails loudly — the Grafana dashboard just goes flat.
- **The healthchecks.io cron task still exists** under Data Protection. It is not managed by
  `truenas-infra`, so nothing would restore it.
- **NFS and SMB are serving.** Un-hibernate the databases, confirm PVCs are `Bound` and pods are
  `Running`, and let a Time Machine backup complete.
- **Renovate is un-suspended and its next run completes.** This is the symmetric half of the step 4
  suspend, and the check that proves the export came back usable for a client that mounts it fresh
  on every run rather than holding a mount across the reboot:

    ```bash
    kubectl -n renovate patch cronjob renovate-bot -p '{"spec":{"suspend":false}}'

    # Within ~30 min: one job, Complete, and a DURATION of roughly 3 minutes
    kubectl -n renovate get jobs
    ```
- **Prometheus' `truenas` job is UP** at `https://prometheus.${DOMAIN}/targets`, and the
  "TrueNAS Scale / Overview" dashboard has data again.
- **Expect a new REST API deprecation alert.** That is `discover.sh` and `check-credentials.sh`
  doing their job on a 25.10 box, not a fault.

Finally, re-run `discover.sh` and commit the refreshed `imports/*.json` as the after-picture.

### 7. Rollback, if it comes to that

1. **System → Boot.**
2. Select the boot environment recorded in step 3 and **Activate** it.
3. Reboot.

One reboot, and the old release is back with its configuration intact. This is why step 3 is not
optional.

Rollback does **not** undo anything the 25.10 middleware migrated on first boot — the SMB preset
rewrite, for one. Re-run `tf.sh plan` after rolling back too.

## History

- **2026-08-21** — evaluated 25.04.2.6 → 25.10.6 and wrote this page. Read-only recon found no VMs,
  no Incus instances, no scheduled SMART tests, no certificate authorities, no directory services and
  no replication tasks, so almost every 25.10 breaking change is inapplicable here. The plan and its
  progress tracker live in `truenas-infra` under `docs/plans/truenas-25-10-upgrade/`. Not yet
  executed.

## References

- [TrueNAS Software Status](https://www.truenas.com/docs/softwarestatus/) — which train is current,
  and the two-newest-are-maintained policy. There are no published EOL dates; see
  [EOL Monitoring](../infrastructure/eol-monitoring.md)
- [25.10 (Goldeye) Version Notes](https://www.truenas.com/docs/scale/25.10/gettingstarted/versionnotes/) — the breaking-change list the table above is drawn from
- [TrueNAS](../infrastructure/truenas.md) — what the cluster depends on this box for
- [TrueNAS Docker Default Interface Fix](truenas-docker-default-interface.md) — if the apps subsystem does not come back
