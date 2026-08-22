# TrueNAS Monitoring

Prometheus-based monitoring for TrueNAS SCALE (25.04+) using the Graphite exporter pattern. TrueNAS pushes Netdata metrics via the Graphite protocol to a `graphite-exporter` running in the cluster, which Prometheus then scrapes.

## Architecture

```
TrueNAS (Netdata) --[Graphite/TCP:2003]--> graphite-exporter --[HTTP:9108]--> Prometheus --> Grafana
                                                                                  |
                                                                            Alertmanager --> ntfy
```

- **graphite-exporter**: Runs in the `prometheus` namespace, exposed as a LoadBalancer Service on `${LAN_PREFIX}.32`
- **API exporter**: `truenas-api-exporter` — the one component that *dials* TrueNAS instead of
  waiting to be pushed, for the two things netdata will not send. Named for disk temperature, which
  was the only one when it was written; it now carries dataset space too.
- **Mapping config**: Translates Graphite metric names to Prometheus labels (from [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus))
- **Dashboard**: Auto-provisioned Grafana dashboard covering CPU, memory, disk temps, network,
  ZFS ARC, and a Capacity row — pool fullness, pool used and free, per-dataset usage against
  refquota, and snapshot space. The capacity panels were added after the observation that the
  dataset metrics existed only as alert rules, with nothing to look at before one fired.

## Cluster-Side Configuration

All cluster-side resources live in `infrastructure/prometheus/`:

| File | Contents |
|------|----------|
| `graphite-exporter.yaml` | ConfigMap (mapping rules) + Deployment + LoadBalancer Service |
| `truenas-dashboard.yaml` | Grafana dashboard ConfigMap (auto-discovered via `grafana_dashboard: "1"` label) |
| `helm.yaml` | Scrape config (`additionalScrapeConfigs`) + alert rules (`additionalPrometheusRulesMap`) |

## TrueNAS-Side Configuration

### Step 1: Configure Reporting Exporter

1. Navigate to **Reporting > Exporters** in the TrueNAS UI
2. Click **Add** and configure:
    - **Name**: `graphite-k8s` (or any descriptive label)
    - **Type**: `GRAPHITE`
    - **Namespace**: your TrueNAS hostname (e.g., `truenas`) — this becomes the instance label in Prometheus metrics
    - **Destination IP**: `${LAN_PREFIX}.32`
    - **Destination Port**: `2003`
    - **Prefix**: `truenas`
    - **Update Every**: `15` (seconds)
    - **Send Names Instead Of Ids**: enabled

### Step 2: Restore Netdata Collectors

TrueNAS ships with many Netdata collectors disabled for security hardening, and **every update resets
`/etc/netdata/netdata.conf` back to that state.** Restoring them is a manual step after each upgrade
— see [Upgrading TrueNAS](../misc/truenas-upgrade.md), where it is the step most likely to be
skipped, because nothing fails loudly. The dashboard just goes flat.

It is not only the dashboard. The collectors this restores are what four of the `truenas-health`
alert rules are built on:

| Collector | What stops working without it |
|---|---|
| `/proc/spl/kstat/zfs/arcstats` | `truenas_arcstats` — the ARC hit rate alert |
| `diskspace` | `disk_bytes_used` — the pool capacity alert |
| `/proc/meminfo` | `physical_memory` — the memory pressure alert |
| `/proc/diskstats`, physical disk metrics | disk I/O charts, and `disk_temperature` coverage |

Apply the config from the Supporterino project, **pinned to a commit**:

```bash
# On TrueNAS
SHA=b092856a7fb21196629b3c3cd2e57cbcad736e78
SUM=37df02c6cdd8f0f8cf1548941889fc6760557842a63e0c357a518d112d1fb134

# Keep the file the update installed, named for the release that installed it
sudo cp -a /etc/netdata/netdata.conf "/etc/netdata/netdata.conf.$(cat /etc/version).stock"

# Fetch to a temp path and verify BEFORE anything is written to /etc
curl -fsSL -o /tmp/netdata.conf \
  "https://raw.githubusercontent.com/Supporterino/truenas-graphite-to-prometheus/$SHA/netdata.conf"
echo "$SUM  /tmp/netdata.conf" | sha256sum -c -

sudo install -o root -g root -m 644 /tmp/netdata.conf /etc/netdata/netdata.conf
sudo systemctl restart netdata
```

Confirm it took — the count is the quickest signal, since the stock file enables 8 and this one 20:

```bash
grep -c "= yes" /etc/netdata/netdata.conf   # expect 20
systemctl is-active netdata                 # expect: active
```

> **Note**
> **Pin the SHA; do not fetch `main`.** This procedure writes a third-party file into `/etc` on the
> storage box. Tracking a branch means the content is whatever upstream happened to push that day,
> and the machine that runs this is the one holding every backup in the house. The pin above and
> `main` were byte-identical when this was written — pinning costs nothing today and is the whole
> protection later. When bumping the pin, re-read the diff and update `SUM` in the same commit.

### Step 3: Configure Email Alerts (Optional)

For TrueNAS update notifications and pool health alerts, configure system-level
SMTP and verify the alert service is enabled.

#### 3a. Configure SMTP

1. Navigate to **System > General > Email**
2. Configure the outgoing mail settings:
    - **Send Mail Method**: `SMTP`
    - **From Email**: your email address
    - **From Name**: `TrueNAS` (or any sender name)
    - **Outgoing Mail Server**: `smtp.gmail.com`
    - **Mail Server Port**: `587`
    - **Security**: `STARTTLS`
    - **SMTP Authentication**: enabled
    - **Username**: your Gmail address
    - **Password**: a Gmail App Password (not your regular password)
3. Click **Send Test Email** to verify delivery

#### 3b. Verify Alert Service

1. Navigate to **Alert Settings > Alert Services**
2. Ensure the **E-Mail** alert service exists, is **Enabled**, and the Level is set to **Warning**
    - TrueNAS includes a default E-Mail alert service — if it's already present, no changes are needed
3. Under **Alert Settings**, ensure these alert categories are set to WARNING or higher:
    - System Update Available
    - Application Update Available
    - Pool Status (degraded ZFS pools)

## What the graphite pipeline does not carry

Two families come from the API exporter (`data/truenas_api_exporter.py`) rather than netdata,
because netdata does not send them at all.

| Family | Why not graphite |
|---|---|
| `disk_temperature` | TrueNAS 25.10 moved it to a python.d chart netdata declines to export. |
| `truenas_dataset_*` | netdata's `diskspace` collector reports **boot-pool paths only** — `_root`, `_var_log`, `_tmp`, `_usr`. There is no `/mnt/pool*` mountpoint in `disk_bytes_used`. |

!!! warning "`TrueNASBootPoolHighDiskUtilization` is boot-pool only"
    It was called `TrueNASHighDiskUtilization` and read like the pool capacity alert. It never
    watched a single dataset behind a PVC, and reported healthy the whole time it was not watching
    them — a Renovate cache reached 34G, a third of `pool/k8s-nfs`, over 141 days with nothing able
    to see it. The rule is kept because a full `/var/log` on the NAS still matters; the
    `TrueNASDataset*` rules are what cover the pool.

The dataset metrics, keyed by `dataset` (e.g. `pool/k8s-nfs`):

| Metric | Meaning |
|---|---|
| `truenas_dataset_used_bytes` | `usedbydataset` — referenced data, **excluding** snapshots |
| `truenas_dataset_snapshots_bytes` | `usedbysnapshots` — released only as snapshots expire |
| `truenas_dataset_available_bytes` | writable space remaining |
| `truenas_dataset_refquota_bytes` | referenced-data limit; **0 means unset** |
| `truenas_dataset_quota_bytes` | total limit including snapshots; 0 means unset |

Two things about the alert expressions are load-bearing:

* **`usedbydataset`, not `used`.** `refquota` bounds referenced data and does not count snapshots.
  Measured 2026-08-22: wiping 34G moved 27.5 GiB into `usedbysnapshots` while refquota headroom
  recovered in full immediately. Dividing `used` by `refquota` would page for space the quota does
  not bound.
* **The `> 0` filter on the denominator.** `0` is ZFS's encoding for "no refquota", so without it
  every unbounded dataset divides by zero, returns `+Inf`, and fires. Verified:
  `vector(100) / (vector(0) > 0)` is empty, `vector(100) / vector(0)` is `+Inf`.

The exporter needs `DATASET_READ` on the `prom-exporter` account, granted in
[`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra). Without it the exporter keeps
serving temperatures and `truenas_dataset_scrape_success` goes to 0 — it degrades rather than dies.

## Alert Rules

The following Prometheus alert rules are defined in `helm.yaml`:

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| TrueNASDiskTemperatureHigh | Disk temp > 65°C | 5m | warning |
| TrueNASDiskTemperatureCritical | Disk temp > 70°C | 2m | critical |
| TrueNASHighCpuUsage | CPU usage > 90% | 5m | warning |
| TrueNASHighMemoryUsage | Memory usage > 90% | 5m | warning |
| TrueNASZfsArcHitRatioLow | ZFS ARC hit ratio < 50% | 15m | warning |
| TrueNASPoolDegraded | A pool is degraded, faulted, unavailable or removed | 5m | critical |
| TrueNASBootPoolHighDiskUtilization | Boot-pool filesystem usage > 85%, excluding tmpfs mountpoints | 10m | warning |
| TrueNASDatasetNearRefquota | Dataset `usedbydataset` > 80% of its refquota | 30m | warning |
| TrueNASDatasetRefquotaCritical | Dataset `usedbydataset` > 95% of its refquota | 10m | critical |
| TrueNASDatasetRefquotaFillingUp | Over half its refquota **and** projected to reach it within 14 days | 6h | warning |
| TrueNASSnapshotsExceedLiveData | Snapshots > 50 GiB **and** > 1.5x the dataset's live data | 6h | warning |
| TrueNASPoolLowFreeSpace | Pool > 80% full | 30m | warning |
| TrueNASPoolCriticallyLowFreeSpace | Pool > 90% full | 10m | critical |
| TrueNASPoolFillingUp | Pool over half full **and** projected to fill within 30 days | 6h | warning |
| TrueNASMetricSeriesMissing | One of six metric families has stopped arriving | 10m | warning |
| TrueNASDatasetExporterFailing | `pool.dataset.query` failing, values frozen | 10m | warning |
| TrueNASDiskTempExporterFailing | `disk.temperatures` failing, values frozen | 10m | warning |

Alerts flow through the existing pipeline: Prometheus > Alertmanager > alertmanager-ntfy bridge > ntfy push notifications.

### Why the pool thresholds are a percentage

They used to be absolute — 500 GiB free for the warning, 200 GiB for the critical. On an 8.1 TiB
pool that is 94% and 97.6% full: both are past the point where ZFS still writes well, and well
past the point where there is time to choose between deleting, expiring snapshots and buying
disks. 80% is also where ZFS allocation switches from first-fit to best-fit and throughput starts
to drop, so it is worth knowing about for its own sake.

Capacity has to be derived, because the API exposes no pool size without a `POOL_READ` grant that
lives in [`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra). On the root dataset
the recursive `used` plus `available` is the usable size, and `used` comes from the
`pool.dataset.query` the exporter already makes under `DATASET_READ`. It is exported as
`truenas_dataset_total_used_bytes`, named deliberately apart from `truenas_dataset_used_bytes`
so the refquota rules cannot pick up the wrong one.

### The `*FillingUp` rules

Everything else here is a static line: it tells you that you have arrived, not that you are on the
way. The trend rules follow the shape upstream uses for `NodeFilesystemSpaceFillingUp` — a
utilisation guard **and** a `predict_linear` projection — because a projection on its own is
noise. A pool that wobbles by a gigabyte around a flat mean extrapolates to zero happily; the
guard is what stops that from paging.

The input window is 7d rather than the 24h upstream uses, because this storage fills over weeks
rather than hours. Prometheus history here only begins 2026-08-21, when the stack moved off an
`emptyDir`; `predict_linear` uses whatever the window holds, so these are correct but
conservative until the window fills.

### Known gap: no wear or SMART data for the pool drives

The six NVMe drives report temperature and nothing else. There is no wear-levelling percentage, no
available-spare ratio, no media-error count — the figures the Proxmox hosts have had all along and
that `ProxmoxNvmeWearHigh` and friends now watch. Closing it means a new `disk.smart_attributes`
call in the API exporter and most likely another permission grant in
[`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra).

A drive wearing out gives no warning through a filesystem. It reports healthy right up to the
point the controller goes read-only.

## Verification

After deploying and configuring both sides:

1. **Graphite exporter metrics**: `http://${LAN_PREFIX}.32:9108/metrics` should show TrueNAS metrics
2. **Prometheus targets**: Check `https://prometheus.${DOMAIN}/targets` -- the `truenas` job should show as UP
3. **Alert rules**: Check `https://prometheus.${DOMAIN}/rules` -- the `truenas-health` group should be listed
4. **Grafana dashboard**: Check `https://grafana.${DOMAIN}` -- "TrueNAS Scale / Overview" dashboard should appear

## References

- [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus) -- mapping config, dashboards, and netdata.conf
- [prom/graphite-exporter](https://github.com/prometheus/graphite_exporter) -- official Prometheus graphite exporter
