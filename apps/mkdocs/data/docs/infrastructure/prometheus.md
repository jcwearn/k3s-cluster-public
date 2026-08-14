# kube-prometheus-stack

*Comprehensive monitoring, alerting, and visualization for Kubernetes - deployed with **Helm** and managed by **FluxCD**.*

---

## Helm release at-a-glance

| Setting                | Value                                                                                                    |
| ---------------------- | -------------------------------------------------------------------------------------------------------- |
| **Chart**              | `kube-prometheus-stack`                                                                                  |
| **Version**            | `72.3.0`                                                                                                 |
| **Repository**         | `prometheus-community`                                                                                   |
| **URL**                | [https://prometheus-community.github.io/helm-charts](https://prometheus-community.github.io/helm-charts) |
| **HelmRelease**        | `prometheus/kube-prometheus-stack`                                                                       |
| **Reconcile interval** | Every 10 minutes                                                                                         |
| **CRDs**               | Installed (`Create`) and replaced on upgrade (`CreateReplace`)                                           |
| **Namespace**          | `prometheus` (created automatically)                                                                     |

<details>
<summary>HelmRelease source YAML</summary>

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  url: https://prometheus-community.github.io/helm-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: prometheus
spec:
  chart:
    spec:
      chart: kube-prometheus-stack
      version: 72.3.0
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  install:
    createNamespace: true
    crds: Create
  upgrade:
    crds: CreateReplace
  # …valuesFrom & values trimmed for brevity
```

</details>

---

## Prometheus

* **Service** - `LoadBalancer` with VIP **${LAN_PREFIX}.3**; exposed to the Tailnet via `tailscale.com/expose: "true"` (hostname `prometheus`).
* **Ingress** - `prometheus.${DOMAIN}` served by the NGINX ingress controller with HTTPS enforced.
* **Retention & storage** - default (2 weeks); backed by a TrueNAS NFS PVC (configured separately).

### Key annotations

```yaml
service:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "prometheus"
    kube-vip.io/loadbalancerIPs: "${LAN_PREFIX}.3"
ingress:
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    external-dns.alpha.kubernetes.io/target: "k3s-ingress.${TAILNET}"
```

---

## Alertmanager

|                  | Value                                                   |
| ---------------- | ------------------------------------------------------- |
| **Ingress host** | `alerts.${DOMAIN}`                                      |
| **LB VIP**       | `${LAN_PREFIX}.18` (hostname `alertmanager`)              |
| **Receivers**    | `null`, `ntfy` (all alerts), `healthcheck` (Watchdog → Healthchecks.io) |

The **ntfy** receiver posts to the side-car service `alertmanager-ntfy-svc` (port 4081). Credentials are injected via **SOPS-encrypted** secret `prometheus-secrets`:

```yaml
valuesFrom:
  - name: prometheus-secrets
    valuesKey: NTFY_USERNAME
    targetPath: alertmanager.config.receivers[1].webhook_configs[0].http_config.basic_auth.username
  - name: prometheus-secrets
    valuesKey: NTFY_PASSWORD
    targetPath: alertmanager.config.receivers[1].webhook_configs[0].http_config.basic_auth.password
```

A small volume mounts `/passwords/alertmanager-ntfy-password` inside the Alertmanager container for compatibility with scripts or templates that need the password on disk.

### Dead man's switch

Because ntfy is self-hosted on the same cluster, a cluster-wide outage would also take down the alerting path — meaning you'd get no notification that monitoring is gone. A **dead man's switch** closes this gap by using an external service to detect silence.

**How it works:** Prometheus ships a built-in `Watchdog` alert that is *always* firing. Alertmanager routes it to the `healthcheck` receiver, which pings a [Healthchecks.io](https://healthchecks.io) endpoint every **5 minutes**. If pings stop arriving (cluster down, Alertmanager crashed, etc.), Healthchecks.io sends an email after the grace period expires.

**Route configuration:**

```yaml
routes:
  - receiver: healthcheck
    matchers:
      - alertname = "Watchdog"
    group_wait: 0s
    group_interval: 1m
    repeat_interval: 5m
```

* `group_wait: 0s` — send immediately, no batching.
* `group_interval: 1m` — recheck every minute.
* `repeat_interval: 5m` — re-ping at least every 5 minutes.

**Secret injection:** The ping URL is stored in the SOPS-encrypted `prometheus-secrets` and injected into the HelmRelease values:

```yaml
valuesFrom:
  - name: prometheus-secrets
    valuesKey: HEALTHCHECK_WATCHDOG_URL
    targetPath: alertmanager.config.receivers[2].webhook_configs[0].url
```

**Healthchecks.io check settings:**

| Setting    | Value  |
| ---------- | ------ |
| **Period** | 5 min  |
| **Grace**  | 5 min  |

With these settings, an email fires roughly **10 minutes** after the cluster stops pinging (5 min period + 5 min grace).

**Testing:** Scale down Alertmanager (`kubectl -n prometheus scale statefulset alertmanager-kube-prometheus-stack-alertmanager --replicas=0`), then wait ~10 minutes for the Healthchecks.io email. Scale back up afterward.

---

## Grafana

* **Ingress** - `grafana.${DOMAIN}` (HTTPS enforced).
* **Admin credentials** - pulled from `prometheus-secrets` (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`).
* **Prune** - set to `true`, so only your hand-picked dashboards are kept; built-in example dashboards are removed on every sync.

> **Tip:** add dashboards via `ConfigMap` or `GrafanaDashboard` CRDs - they will survive chart upgrades.

---

## Disabled components & rules

This cluster runs **k3s**, so several Kubernetes control-plane exporters and rule groups are unnecessary and disabled:

* `kubeControllerManager`, `kubeProxy`, `kubeScheduler`
* Corresponding default rule groups for alerting/recording

---

## Custom Prometheus rules

File `additionalPrometheusRulesMap.pod-not-healthy` adds a rule group that surfaces the most common pod-level issues:

| Alert                             | Purpose                                | Firing threshold   |
| --------------------------------- | -------------------------------------- | ------------------ |
| `KubernetesPodNotHealthy`         | Pod stuck in `Pending/Unknown/Failed`  | > 0 pods for 1 min |
| `KubernetesDaemonsetRolloutStuck` | Not all DaemonSet pods scheduled/ready | 10 min             |
| `ContainerHighCpuUtilization`     | CPU > 80 % of request                  | 2 min              |
| `ContainerHighMemoryUsage`        | Memory > 80 % of limit                 | 2 min              |
| `KubernetesContainerOomKiller`    | Container OOMKilled ≥ 1 in 10 min      | immediate          |
| `KubernetesPodCrashLooping`       | > 3 restarts in 1 min                  | 2 min              |

Feel free to extend this map with service-specific rules - Flux will pick them up automatically.

---

## Access summary

| Component        | URL                            | Auth                             |
| ---------------- | ------------------------------ | -------------------------------- |
| **Grafana**      | `https://grafana.${DOMAIN}`    | `prometheus-secrets` admin creds |
| **Prometheus**   | `https://prometheus.${DOMAIN}` | (none)                           |
| **Alertmanager** | `https://alerts.${DOMAIN}`     | (none)                           |

All three UIs are additionally reachable inside the Tailnet via the service hostnames declared in the `tailscale.com/hostname` annotations.

---

## Secret management

`prometheus-secrets` is encrypted with **SOPS + age** and decrypted by Flux **before** Helm runs. Updates to credentials only require editing the secret and committing the change - no manual `helm upgrade` necessary.

---

## Upgrading the stack

1. Bump `spec.chart.spec.version` in `helm.yaml`.
2. Commit & push.
3. Flux will reconcile within 10 minutes and apply CRDs with `CreateReplace`.

> **Heads-up:** major chart upgrades may introduce breaking changes - consult the [chart CHANGELOG](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#changelog) first.

---

## Further reading

* **Chart docs:** [https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
* **Prometheus Operator:** [https://github.com/prometheus-operator/prometheus-operator](https://github.com/prometheus-operator/prometheus-operator)
* **Flux Helm Controller:** [https://fluxcd.io/flux/components/helm/](https://fluxcd.io/flux/components/helm/)
