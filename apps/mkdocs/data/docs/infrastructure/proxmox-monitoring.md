# Proxmox Monitoring

Two-layer monitoring for the three Proxmox VE hypervisors (pve-01/02/03) using `prometheus-pve-exporter` for API-level metrics and `node_exporter` for OS-level host metrics.

## Architecture

```
Proxmox API (8006) --[HTTP]--> pve-exporter (in-cluster) --[HTTP:9221]--> Prometheus --> Grafana
                                                                              |
PVE hosts (:9100) --[HTTP]----> node_exporter (on hosts) ----[HTTP:9100]--> Prometheus
                                                                              |
                                                                        Alertmanager --> ntfy
```

- **pve-exporter**: Runs in the `prometheus` namespace, queries the Proxmox REST API using a read-only API token
- **node_exporter**: Installed directly on each Proxmox host, provides deep OS-level metrics
- **Dashboards**: "Proxmox via Prometheus" (Grafana 10347) and "Node Exporter Full" (Grafana 1860)

## Targets

| Host | IP | Role |
|------|----|------|
| pve-01 | ${LAN_PREFIX}.21 | Proxmox hypervisor |
| pve-02 | ${LAN_PREFIX}.22 | Proxmox hypervisor |
| pve-03 | ${LAN_PREFIX}.23 | Proxmox hypervisor |

## Cluster-Side Configuration

All cluster-side resources live in `infrastructure/prometheus/`:

| File | Contents |
|------|----------|
| `pve-exporter.yaml` | ConfigMap (auth config) + Deployment + ClusterIP Service |
| `pve-exporter-secret.sops.yaml` | SOPS-encrypted API token for Proxmox authentication |
| `proxmox-dashboard.yaml` | Grafana dashboard ConfigMap — "Proxmox via Prometheus" (10347) |
| `helm.yaml` | Scrape configs (`pve` + `proxmox-nodes` jobs) + alert rules (`proxmox-health`) |

## Proxmox-Side Configuration

### Step 1: Create API Token

On any Proxmox node, create a dedicated monitoring user and API token:

```bash
# Create a dedicated monitoring user
pveum user add monitoring@pve --comment "Prometheus monitoring"

# Assign read-only PVEAuditor role at datacenter level
pveum acl modify / --user monitoring@pve --role PVEAuditor

# Create an API token (--privsep=0 to inherit user permissions)
pveum user token add monitoring@pve prometheus --privsep=0
# Save the displayed token value -- it is shown only once
```

After obtaining the token, update the SOPS secret:

```bash
sops infrastructure/prometheus/pve-exporter-secret.sops.yaml
# Replace REPLACE_WITH_ACTUAL_TOKEN with the real token value
```

### Step 2: Install node_exporter on Each Host

On each Proxmox host (pve-01, pve-02, pve-03):

```bash
apt update && apt install -y prometheus-node-exporter

# Verify it is running
systemctl status prometheus-node-exporter
curl -s http://localhost:9100/metrics | head -5
```

The node_exporter service starts automatically and listens on port 9100.

## Alert Rules

The following Prometheus alert rules are defined in `helm.yaml` under the `proxmox-health` group:

### API-Level Alerts (pve-exporter)

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| ProxmoxNodeDown | Node unreachable via API | 1m | critical |
| ProxmoxVMDown | VM down | 5m | warning |
| ProxmoxHighCPU | Node CPU > 90% (API) | 10m | warning |
| ProxmoxHighMemory | Node memory > 90% (API) | 10m | warning |
| ProxmoxStorageAlmostFull | Storage > 85% used | 10m | warning |
| ProxmoxStorageFull | Storage > 95% used | 5m | critical |
| ProxmoxStorageFillingUp | Storage over half full **and** projected to fill within 30 days | 6h | warning |

Every one of these is wrapped in `max by (id)`. Each pve-exporter target reports the whole
cluster, so all three scrapes carry all three nodes and all six storages; without the aggregation
a single node going down raised the same alert three times, distinguished only by which host
answered. The `id` label already names the subject, so dropping `instance` loses nothing.

`ProxmoxStorage*` is additionally filtered to `id=~"storage/.*"`. Unfiltered it also evaluated
`node/*` — the host root filesystem, already covered below — and `qemu/*`, where usage reads 0
without the guest agent and the ratio means nothing.

### Host-Level Alerts (node_exporter)

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| ProxmoxHostHighCPU | OS-level CPU > 90% | 10m | warning |
| ProxmoxHostDiskAlmostFull | Filesystem > 85% used | 10m | warning |
| ProxmoxHostDiskFull | Filesystem > 95% used | 5m | critical |

### NVMe Health (node_exporter textfile collector)

The hosts have been exporting a full NVMe SMART set through `nvme.prom` all along and nothing
read any of it. The drives sit at 9-10% wear after roughly 474 days, which is fine, and is
exactly why it is worth watching: the number only becomes interesting long after anyone has
stopped thinking about it. A drive wearing out gives no warning through a filesystem — it reports
healthy right up to the point the controller goes read-only.

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| ProxmoxNvmeWearHigh | > 80% of rated write endurance consumed | 1h | warning |
| ProxmoxNvmeWearCritical | > 90% of rated write endurance consumed | 1h | critical |
| ProxmoxNvmeSpareLow | Available spare at or below the drive's own reported threshold | 15m | critical |
| ProxmoxNvmeCriticalWarning | The controller's critical-warning bitfield is non-zero | 5m | critical |
| ProxmoxNvmeMediaErrors | Any increase in unrecovered data-integrity errors | 5m | warning |

### LVM Thin-Pool Alerts (node_exporter textfile collector)

The guests live on local LVM-thin. The PVE API reports the **data** fullness of those pools, which
`ProxmoxStorageAlmostFull` already watches. It does not report **metadata** fullness, and that is
the one that does not forgive: when the metadata LV fills, the pool goes read-only and deleting
data does not recover it, because freeing a block is itself a metadata write. Recovery is
`lvconvert --repair` against a spare LV, offline, on a hypervisor whose guests have all stopped
writing.

It is also the failure nothing else would hint at, because metadata grows with the number of
distinct blocks rather than their volume — it can approach full while data sits at 13%, which is
where these pools are today.

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| ProxmoxThinPoolMetadataAlmostFull | Thin-pool metadata > 80% | 15m | warning |
| ProxmoxThinPoolMetadataFull | Thin-pool metadata > 90% | 5m | critical |
| ProxmoxThinPoolMetricsStale | `lvm_thin.prom` not rewritten in over 20 minutes | 10m | warning |
| ProxmoxThinPoolMetricsMissing | No host reporting `lvm_thin_metadata_percent` | 6h | warning |

The last two exist because a stopped timer looks like nothing at all: node_exporter keeps serving
whatever the file last contained, so `lvm_thin_metadata_percent` stays resolvable and stays low.

#### Installing the collector

The metrics come from `/usr/local/bin/lvm-thin-metrics.sh` and a systemd timer, installed by
`apps/ansible/data/playbooks/configure-lvm-thin-metrics.yml`. The textfile collector itself was
already enabled on all three hosts — it serves `apt.prom` and `nvme.prom` out of
`/var/lib/prometheus/node-exporter` — so nothing about node_exporter changes.

Unlike the other `configure-*` CronJobs, this one is **not suspended**. Those write a setting
once; this installs a collector, and re-asserting it weekly (Sundays 04:00) means a rebuilt or
reimaged host starts reporting again without anyone remembering to run a playbook. The playbook is
idempotent.

Run it immediately rather than waiting for the first weekly tick:

```bash
kubectl create job -n ansible \
  --from=cronjob/ansible-configure-lvm-thin-metrics \
  ansible-configure-lvm-thin-metrics-manual
kubectl logs -n ansible -l job-name=ansible-configure-lvm-thin-metrics-manual -f
```

`ProxmoxThinPoolMetricsMissing` uses a 6h `for:` rather than the 10m the other staleness guards
use, precisely to cover the window between these rules landing through Flux and that job running.

Alerts flow through the existing pipeline: Prometheus > Alertmanager > alertmanager-ntfy bridge > ntfy push notifications.

## Verification

After deploying the cluster-side resources and completing the Proxmox-side steps:

1. **pve-exporter metrics**: `curl http://<pve-exporter-svc-cluster-ip>:9221/pve?target=${LAN_PREFIX}.21&module=default&cluster=1&node=1`
2. **node_exporter on hosts**: `curl http://${LAN_PREFIX}.21:9100/metrics`
3. **Prometheus targets**: Check `https://prometheus.${DOMAIN}/targets` -- the `pve` and `proxmox-nodes` jobs should show as UP
4. **Alert rules**: Check `https://prometheus.${DOMAIN}/rules` -- the `proxmox-health` group should be listed
5. **Grafana dashboards**: Check `https://grafana.${DOMAIN}` -- search for "Proxmox" and "Node Exporter Full"

## References

- [prometheus-pve/prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter) -- Proxmox VE exporter for Prometheus
- [Grafana Dashboard 10347](https://grafana.com/grafana/dashboards/10347-proxmox-via-prometheus/) -- "Proxmox via Prometheus"
- [Grafana Dashboard 1860](https://grafana.com/grafana/dashboards/1860-node-exporter-full/) -- "Node Exporter Full"
- [Proxmox VE API Tokens](https://pve.proxmox.com/wiki/User_Management#pveum_tokens) -- API token documentation
