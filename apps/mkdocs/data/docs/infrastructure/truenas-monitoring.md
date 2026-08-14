# TrueNAS Monitoring

Prometheus-based monitoring for TrueNAS SCALE (25.04+) using the Graphite exporter pattern. TrueNAS pushes Netdata metrics via the Graphite protocol to a `graphite-exporter` running in the cluster, which Prometheus then scrapes.

## Architecture

```
TrueNAS (Netdata) --[Graphite/TCP:2003]--> graphite-exporter --[HTTP:9108]--> Prometheus --> Grafana
                                                                                  |
                                                                            Alertmanager --> ntfy
```

- **graphite-exporter**: Runs in the `prometheus` namespace, exposed as a LoadBalancer Service on `${LAN_PREFIX}.32`
- **Mapping config**: Translates Graphite metric names to Prometheus labels (from [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus))
- **Dashboard**: Auto-provisioned Grafana dashboard covering CPU, memory, disk temps, network, ZFS ARC, and filesystem usage

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

### Step 2: Restore Netdata Collectors (TrueNAS 25.04)

TrueNAS 25.04 disabled many Netdata collectors for security hardening. To restore full metrics (disk SMART temps, ZFS ARC stats, etc.), deploy a custom Netdata config.

Download the configuration from the Supporterino project and apply it:

```bash
# SSH into TrueNAS
sudo cp /etc/netdata/netdata.conf /etc/netdata/netdata.conf.bak
sudo curl -o /etc/netdata/netdata.conf \
  https://raw.githubusercontent.com/Supporterino/truenas-graphite-to-prometheus/main/netdata.conf
sudo systemctl restart netdata
```

**Important**: This file must be reapplied after each TrueNAS update, as updates reset `/etc/netdata/netdata.conf`.

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

## Alert Rules

The following Prometheus alert rules are defined in `helm.yaml`:

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| TrueNASDiskTemperatureHigh | Disk temp > 60°C | 5m | warning |
| TrueNASDiskTemperatureCritical | Disk temp > 70°C | 2m | critical |
| TrueNASHighCpuUsage | CPU usage > 90% | 5m | warning |
| TrueNASHighMemoryUsage | Memory usage > 90% | 5m | warning |
| TrueNASZfsArcHitRatioLow | ZFS ARC hit ratio < 50% | 15m | warning |
| TrueNASHighDiskUtilization | Filesystem usage > 85% | 10m | warning |

Alerts flow through the existing pipeline: Prometheus > Alertmanager > alertmanager-ntfy bridge > ntfy push notifications.

## Verification

After deploying and configuring both sides:

1. **Graphite exporter metrics**: `http://${LAN_PREFIX}.32:9108/metrics` should show TrueNAS metrics
2. **Prometheus targets**: Check `https://prometheus.${DOMAIN}/targets` -- the `truenas` job should show as UP
3. **Alert rules**: Check `https://prometheus.${DOMAIN}/rules` -- the `truenas-health` group should be listed
4. **Grafana dashboard**: Check `https://grafana.${DOMAIN}` -- "TrueNAS Scale / Overview" dashboard should appear

## References

- [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus) -- mapping config, dashboards, and netdata.conf
- [prom/graphite-exporter](https://github.com/prometheus/graphite_exporter) -- official Prometheus graphite exporter
