# Cluster Infrastructure

These components provide the plumbing that lets the workloads run
smoothly — from storage and ingress to certificates and private
networking.  Each page below goes deeper into configuration details,
Helm values, and any cluster-specific tweaks.

| Add-on | What it does | Docs |
|--------|--------------|------|
| **kube-vip** | Keeps the API-server reachable on a floating VIP for HA control-plane and LoadBalancer-style Services. | [Read more](kube-vip.md) |
| **cert-manager** | Automates ACME certificates via Let's Encrypt (DNS-01 using Cloudflare). | [Read more](cert-manager.md) |
| **descheduler** | Evicts pods from over-loaded nodes to rebalance the cluster after restarts. | [Read more](descheduler.md) |
| **external-dns** | Reconciles Kubernetes Ingresses/Services → Cloudflare DNS records. | [Read more](external-dns.md) |
| **Flux Operator** | Manages the Flux installation, GitHub App sync, and push-based webhook reconciliation. | [Read more](flux-operator.md) |
| **reloader** | Restarts workloads when ConfigMaps/Secrets change. | [Read more](reloader.md) |
| **Envoy Gateway** | Gateway API ingress controller (Envoy proxy) with wildcard TLS and Tailnet exposure. | [Read more](envoy-gateway.md) |
| **Prometheus** | Comprehensive monitoring, alerting, and visualization for Kubernetes | [Read more](prometheus.md) |
| **Tailscale Operator** | Publishes any Service onto the Tailnet with a single annotation. | [Read more](tailscale-operator.md) |
| **TrueNAS** | External NAS system providing network storage and data management services. | [Read more](truenas.md) |
| **TrueNAS Monitoring** | Prometheus metrics, Grafana dashboards, and alerts for TrueNAS via Graphite exporter. | [Read more](truenas-monitoring.md) |
| **DNS Monitoring** | Blackbox DNS probes and alerts for the AdGuard resolvers and the resolvers they fall back to. | [Read more](dns-monitoring.md) |
| **Proxmox Monitoring** | PVE exporter + node_exporter metrics, Grafana dashboards, and alerts for Proxmox hypervisors. | [Read more](proxmox-monitoring.md) |
| **EOL Monitoring** | Tracks major-version support windows for Proxmox VE, Debian, Ubuntu and Kubernetes, and alerts before one runs out. | [Read more](eol-monitoring.md) |
| **Postgres Backups** | Nightly base backups and WAL archiving for the CloudNativePG clusters, off-site to Cloudflare R2, with a tested restore runbook. | [Read more](postgres-backups.md) |
| **llama.cpp** | Self-hosted LLM inference server (Qwen3 models, OpenAI-compatible API). | [Read more](llama-cpp.md) |
| **System Upgrade Controller** | Upgrades k3s on the nodes from a pinned `Plan` in Git, one node at a time. | [Read more](system-upgrade-controller.md) |

---

## How this layer is delivered

* **GitOps:** All manifests live under  
  `clusters/prod/infrastructure/` and are reconciled by Flux.
* **Helm Releases:** Managed via `HelmRelease` objects, pinned to
  explicit chart versions for reproducible builds.
* **Secrets:** Cloudflare, Tailscale, and ACME credentials are
  SOPS-encrypted and decrypted by Flux on-the-fly.

> **Tip:** If you add a new infra component, just create  
> `docs/infrastructure/<name>.md`, update the table above, and
> reference it in `mkdocs.yml`.