# Logging (Loki + Alloy)

Every pod's logs, each node's systemd journal and the cluster's Kubernetes events, kept for
30 days and queried from Grafana (**Explore → Loki**).

* **Store:** Flux HelmRelease `loki` in `infrastructure/loki/` (`grafana/loki` chart, SingleBinary mode)
* **Collectors:** Flux HelmReleases `alloy` (DaemonSet) and `alloy-events` (Deployment) in `infrastructure/alloy/`
* **Pipelines:** `infrastructure/alloy/data/config.alloy` and `data/events.alloy`

## Why it exists

Before this, logs lived only on the node that wrote them. On 2026-10-13 that lost two
investigations in one day: the hypervisor-upgrade Jobs from the weekend's outage were cleaned up
(3-day TTL) before anyone read them, and a Renovate pod evicted when its node was shut down left no
logs at all.

## What is collected

| Source | Collector | Labels | Example query |
|--------|-----------|--------|---------------|
| Pod logs | `alloy` DaemonSet, tailing `/var/log/pods` on each node | `namespace`, `pod`, `container`, `app`, `node` | `{namespace="renovate"}` |
| Node journal | `alloy` DaemonSet, reading `/var/log/journal` | `job="node-journal"`, `unit`, `level`, `transport`, `node` | `{job="node-journal", unit="k3s.service", node="k3s-02"}` |
| Kubernetes events | `alloy-events`, one replica, watching the API | `job="kubernetes-events"`, `namespace` | `{job="kubernetes-events", namespace="ansible"}` |

Pod logs are read from the files kubelet writes rather than through the API on purpose: a file
outlives its pod, so a Job that is cleaned up or a pod evicted from a failing node still has its
last lines read. Events are a separate single-replica release because a DaemonSet would send each
one three times.

Proxmox host journals are planned but waiting on the hypervisors joining the tailnet, so they can
push without Loki being exposed on the LAN.

## Storage and retention

* A 20 Gi volume on the `truenas-nfs-logs` StorageClass, backed by its own TrueNAS dataset
  (`pool/k8s-nfs-logs`, managed in `truenas-infra`) with a **20 GiB refquota**. The quota is the
  only ceiling, since per-PVC usage on NFS is not observable; `TrueNASDatasetNearRefquota` pages at 80%.
* The dataset is not snapshotted. Loki deletes its own chunks after 30 days, and a snapshot would
  only keep what retention has already dropped.
* Retention (`retention_period: 720h`) is applied by the compactor every 10 minutes.
* Measured on 2026-10-13: about 470 MB/day of raw logs, so roughly 14 GB over 30 days before compression.
  The `envoy-gateway` controller alone is about 40% of it.

## Querying from a terminal

Loki is not exposed outside the cluster. The API server's service proxy reaches it read-only:

```bash
kubectl get --raw "/api/v1/namespaces/loki/services/loki:3100/proxy/loki/api/v1/labels"
```

## Alerts

Defined in the `logging` group of `infrastructure/prometheus/helm.yaml`. A collector that is down
or crash-looping is already covered by the upstream `KubeDaemonSetRolloutStuck`,
`KubePodCrashLooping` and `TargetDown`; these cover a pipeline that is running but not delivering.

| Alert | Fires when |
|-------|------------|
| `LogShippingStuck` | A collector's pushes have all failed for 15 minutes with none succeeding |
| `LogEntriesDropped` | A collector gave up on a batch; those lines are lost |
| `LokiIngestionStopped` | Loki received no lines at all for 30 minutes |
| `LokiRetentionNotRunning` | The compactor has not applied retention for over 6 hours |

## Gotchas

* **The schema must start before the oldest line Loki accepts.** Loki takes lines up to 7 days old
  (`reject_old_samples_max_age`), but answers a line older than the schema's `from` date with a
  500. Alloy retries a 500 until it gives up, and every line behind it waits. On the first day a
  kube-vip log three days older than the install date did exactly this on k3s-01, so `from` is
  `2026-09-01`. Never move it later or edit that entry: a schema change is a new entry dated in the future.
* **The DaemonSet runs as root, with no capabilities.** The log files are root-only, so nothing
  else can read them. Without `CAP_DAC_OVERRIDE`, root also cannot enter directories owned by
  another user, which is why the read positions live at `/alloy-data` rather than in the image's
  own `/var/lib/alloy`.
* **Check a pipeline change with `alloy validate`** (from the release binary). It rejects unknown
  attributes; `alloy fmt` only checks syntax.
