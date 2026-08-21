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

**System → Boot.** Two things here, and the second is easy to miss.

1. **Write down the name of the active boot environment**, verbatim. This is the entire rollback
   plan, and it is one line. Rollback is one reboot if you have the name and a scavenger hunt if you
   do not — and the API does not help: `/bootenv`, `/boot/environment` and `/system/boot_id` all 404
   on 25.04's REST API, so the UI is the only source.
2. **Set `Keep` to `Yes` on that environment** — the bookmark icon on its row. Boot environments are
   created with `Keep: No`, which means nothing stops the system pruning your rollback target when
   the boot pool needs room. Free space usually makes that unlikely, but *unlikely* is a worse
   guarantee than a flag that costs one click. Leave it set until the new release has soaked, then
   clear it so the environment can age out normally.

Also confirm here that the boot pool has room; anything above a few GB free is plenty for another
boot environment.

Finally, check **System → Alerts** is empty. Starting an upgrade on top of an existing fault means
you cannot tell afterwards which one the upgrade caused.

### 4. Quiesce the cluster

Everything with a PVC on one of the three TrueNAS StorageClasses gets stopped, because an NFS stall
does not fail a pod — it hangs it, and some stay hung after the server returns. Stopping them is
cheaper than diagnosing them.

**Suspend Flux first.** Kustomizations reconcile every ten minutes, so anything scaled to zero
without this comes straight back up in the middle of the window. This is also what makes the restore
trivial: every workload is `replicas: 1` in git, so resuming Flux is what puts them back — there is
no list of replica counts to keep.

```bash
flux suspend kustomization apps prometheus llama-cpp
flux get kustomizations | grep -E 'apps|prometheus|llama-cpp'   # SUSPENDED must be True
```

Leave `cloudnative-pg` running. The operator has to be up to act on the hibernation below.

**Then stop the workloads.** Operator-managed resources are patched at the custom resource, not the
StatefulSet — the operator reverts a scaled StatefulSet the same way Flux reverts a scaled
Deployment.

```bash
# CronJob
kubectl -n renovate patch cronjob renovate-bot -p '{"spec":{"suspend":true}}'

# Plain Deployments and StatefulSets
kubectl -n ebooks scale deploy/calibre-web deploy/shelfmark --replicas=0
kubectl -n immich scale deploy/immich-server deploy/immich-machine-learning deploy/immich-valkey --replicas=0
kubectl -n jellyfin scale deploy/jellyfin --replicas=0
kubectl -n llama-cpp scale deploy/llama-cpp-1-7b deploy/llama-cpp-4b deploy/llama-cpp-8b --replicas=0
kubectl -n n8n scale deploy/n8n --replicas=0
kubectl -n ntfy scale deploy/ntfy-deployment deploy/alertmanager-ntfy-deployment --replicas=0
kubectl -n open-webui scale deploy/open-webui-redis sts/open-webui --replicas=0
kubectl -n paperless-ngx scale deploy/paperless-ngx --replicas=0
kubectl -n prometheus scale deploy/kube-prometheus-stack-grafana --replicas=0
kubectl -n uptime-kuma scale sts/uptime-kuma --replicas=0
kubectl -n zeroclaw scale deploy/zeroclaw --replicas=0

# Prometheus and Alertmanager are operator-managed -- patch the CR
kubectl -n prometheus patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":0}}'
kubectl -n prometheus patch alertmanager kube-prometheus-stack-alertmanager --type=merge -p '{"spec":{"replicas":0}}'

# CloudNativePG clusters cannot be scaled -- `instances` has a floor of 1.
# Declarative hibernation is the supported stop, and does not need the kubectl plugin
for ns in immich n8n paperless-ngx; do
  kubectl -n $ns annotate cluster --all cnpg.io/hibernation=on --overwrite
done
```

Confirm nothing is left holding a mount before you reboot the NAS:

```bash
kubectl get pods -A -o wide | grep -vE 'Running|Completed' ; echo '--- still up on NFS namespaces ---'
for ns in ebooks immich jellyfin llama-cpp n8n ntfy open-webui paperless-ngx prometheus uptime-kuma zeroclaw; do
  kubectl -n $ns get pods --no-headers 2>/dev/null | grep -v Completed
done
```

> **Note**
> **AdGuard stays running.** Its three StatefulSets have NFS volumes, but only `/opt/adguardhome/work`
> — the query log and stats — is on the NAS. The config is not, so DNS resolution does not depend on
> the NAS being up, and taking DNS away from the whole house for the window costs more than the
> exposure is worth. Worst case a pod wedges on a blocked query-log write and needs restarting in
> step 6. Set a fallback resolver on your workstation anyway.

Nothing else here needs DNS: `kubectl` reaches the API server through the kube-vip VIP by address,
and the NAS is reached at `${LAN_PREFIX}.200` directly.

**Record what is already firing before you stop anything.** Otherwise every alert waiting for you
afterwards looks like upgrade fallout:

```bash
kubectl -n prometheus exec sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
  wget -qO- http://localhost:9093/api/v2/alerts
```

Do this before scaling Alertmanager to zero, for obvious reasons.

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
- **NFS and SMB are serving.** Bring the cluster back — the reverse of step 4, databases first so
  nothing starts against a database that is not there yet:

  ```bash
  # Databases out of hibernation first
  for ns in immich n8n paperless-ngx; do
    kubectl -n $ns annotate cluster --all cnpg.io/hibernation=off --overwrite
  done
  kubectl get cluster -A          # wait for "Cluster in healthy state"

  # Then let Flux put everything else back. Every workload is replicas: 1 in git,
  # so this restores the replica counts and un-suspends the CronJob on its own --
  # there is no list to remember, which is the point of suspending rather than editing
  flux resume kustomization apps prometheus llama-cpp
  flux reconcile kustomization apps --with-source
  ```

  Then confirm PVCs are `Bound`, pods are `Running`, and let a Time Machine backup complete. If an
  AdGuard pod wedged on a blocked query-log write, `kubectl -n adguardhome rollout restart sts`
  clears it.
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
- **Expect cluster alert noise that is not about the upgrade.** `KubeJobFailed` fires on
  `kube_job_failed > 0` with `for: 15m` and stays latched until the failed Job object is reaped, so a
  CronJob run that died against the down NAS pages *after* the window looks exactly like a
  consequence of it. Compare against the list captured in step 4 before chasing anything. The
  renovate CronJob is the usual source: it runs `*/30` in UTC — which is the Kubernetes schedule,
  not the `schedule` in `renovate.json`, which is Renovate's own gate on when it opens pull requests
  and says nothing about when the pod runs.

Finally, re-run `discover.sh` and commit the refreshed `imports/*.json` as the after-picture.

### 7. Rollback, if it comes to that

1. **System → Boot.**
2. Select the boot environment recorded in step 3 and **Activate** it.
3. Reboot.

One reboot, and the old release is back with its configuration intact. This is why step 3 is not
optional — both halves of it. The name is what makes the environment findable; `Keep` is what makes
it still be there.

Rollback does **not** undo anything the 25.10 middleware migrated on first boot — the SMB preset
rewrite, for one. Re-run `tf.sh plan` after rolling back too.

## History

- **2026-08-21** — rewrote step 4 after walking it. The original said to hibernate the databases and
  leave everything else alone, which was wrong three ways: Flux reconciles every ten minutes and
  would have undone any scale-down mid-window, the `cnpg` kubectl plugin it assumed is not installed
  anywhere here, and it named three databases when thirteen namespaces hold PVCs on the NAS. Step 4
  now suspends Flux first, patches operator-managed resources at the custom resource rather than the
  StatefulSet, and uses declarative hibernation annotations instead of the plugin. Step 6 gained the
  matching restore, which is mostly just resuming Flux.
- **2026-08-21** — walked steps 1 to 3 for real. Added the `Keep` flag to step 3: every boot
  environment on the box had `Keep: No`, so the rollback target was unprotected, which the page did
  not previously say to check. Also corrected the API note — `/boot/environment` and
  `/system/boot_id` 404 alongside `/bootenv`, so there is no read-only route to the name at all.
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
