# k3s-cluster Homelab

Welcome to **`k3s-cluster`** - the GitOps repository that declaratively manages my bare-metal, three-node **k3s** Kubernetes homelab.

---

## Why this repo exists

* **Reproducible** - every manifest lives in Git; a fresh cluster can be bootstrapped with one FluxCD command.
* **Minimal yet useful** - only the add-ons I actually need to self-host services for my home network.
* **Secure** - secrets encrypted with SOPS + `age`; services exposed only through Tailscale, Cloudflare DNS, or Envoy Gateway with Let's Encrypt.

---

## Hardware snapshot

| Node | CPU/RAM | Storage | OS |
|------|---------|---------|----|
| `k3s-01` | Beelink SER8 - 8 core / 32 GiB | 1 TB NVMe | Ubuntu 24.04 LTS |
| `k3s-02` | Beelink SER8 - 8 core / 32 GiB | 1 TB NVMe | Ubuntu 24.04 LTS |
| `k3s-03` | Beelink SER8 - 8 core / 32 GiB | 1 TB NVMe | Ubuntu 24.04 LTS |

---

## Repository layout

```text
.
├── apps/
│   ├── adguardhome/        # DNS resolver & ad blocker
│   ├── ansible/            # Ansible Runner CronJobs (infra automation)
│   ├── coder/              # Cloud development environments
│   ├── ebooks/             # E-book library (Calibre-Web + Calibre)
│   ├── headlamp/           # Kubernetes dashboard
│   ├── homepage/           # Dashboard
│   ├── immich/             # Photo management
│   ├── it-tools/           # Developer utilities
│   ├── jellyfin/           # Media server
│   ├── mazanoke/           # Image compression
│   ├── mkdocs/             # Documentation site (this site)
│   ├── n8n/                # Workflow automation
│   ├── ntfy/               # Push notifications
│   ├── paperless-ngx/      # Document management
│   ├── open-webui/         # Chat UI for LLMs
│   ├── renovate/           # Dependency update bot (CronJob)
│   ├── stirling-pdf/       # PDF tools
│   ├── uptime-kuma/        # Uptime monitoring
│   ├── withjoy-exporter/   # WithJoy guest list → Google Sheets (CronJob + web trigger)
│   ├── zeroclaw/           # AI personal assistant (Telegram + Gemini)
│   └── external/
│       ├── homeassistant/  # Home automation
│       ├── proxmox/        # Hypervisor UI
│       ├── truenas/        # NAS management UI
│       └── unifi/          # Network controller
├── clusters/
│   └── prod/
├── infrastructure/
│   ├── cert-manager/       # TLS certificate automation
│   ├── cloudnative-pg/     # PostgreSQL operator
│   ├── coredns/            # DNS server configuration
│   ├── envoy-gateway/      # Gateway API ingress (Envoy proxy)
│   ├── external-dns/       # DNS record sync to Cloudflare
│   ├── flux-operator/      # Flux Operator + FluxInstance + webhook receiver
│   ├── kube-vip/           # HA virtual IP for control plane + LoadBalancer
│   ├── llama-cpp/          # Local LLM inference server (Qwen3, CPU)
│   ├── prometheus/         # Monitoring stack (kube-prometheus-stack + TrueNAS/Proxmox monitoring)
│   ├── reloader/           # Auto-restart on ConfigMap/Secret changes
│   ├── tailscale-operator/ # Private VPN overlay
│   └── truenas-nfs/        # NFS storage provisioner
└── README.md
```

FluxCD watches `clusters/prod/` and recursively applies everything under `apps/` and `infrastructure/`. A GitHub webhook triggers immediate reconciliation on push to `main`.

---

## Core add-ons

| Category | Component | Purpose |
|----------|-----------|---------|
| **Networking** | **kube-vip** | Virtual IP for the API server & LoadBalancer IPs |
| | **Flannel** | Simple overlay CNI (default in k3s) |
| **Ingress** | **Envoy Gateway** | Gateway API ingress with Envoy proxy for HTTP/S routing |
| | **Tailscale Operator** | Exposes selected services to Tailnet + Funnel |
| **TLS** | **cert-manager** | ACME certificates via Cloudflare DNS-01 |
| **DNS** | **external-dns** | Creates/updates Cloudflare DNS records |
| | **CoreDNS** | Internal cluster DNS configuration |
| **Storage** | **TrueNAS NFS** | NFS-based persistent storage provisioner |
| **Database** | **CloudNativePG** | PostgreSQL operator for stateful workloads |
| **Secrets** | **SOPS + `age`** | Encrypts Kubernetes Secrets stored in Git |
| **GitOps** | **FluxCD** (via Flux Operator) | Continuously reconciles Git → cluster |
| **Monitoring** | **Prometheus** (kube-prometheus-stack) | Metrics, alerting, and Grafana dashboards |
| | **TrueNAS Monitoring** | Graphite exporter + Prometheus alerts + Grafana dashboard for TrueNAS |
| | **Proxmox Monitoring** | PVE exporter + node_exporter + Prometheus alerts + Grafana dashboards for Proxmox |
| **AI/ML** | **llama.cpp** | Local LLM inference server (Qwen3, OpenAI-compatible API) |
| **Automation** | **Reloader** | Restarts workloads on ConfigMap/Secret changes |

---

## Workloads

| App | Type | Notes |
|-----|------|-------|
| **AdGuard Home** | Deployment + PVC | Local DNS / DoH / DoT resolver |
| **Ansible Runner** | CronJob | Automated infrastructure management |
| **Coder** | Helm | Cloud development environments |
| **Ebooks** | Deployment + PVC | Calibre-Web + Calibre e-book library |
| **Headlamp** | Deployment | Kubernetes dashboard |
| **Homepage** | Deployment | Cluster dashboard |
| **Immich** | Helm | Self-hosted photo management |
| **IT Tools** | Deployment | Developer utilities |
| **Jellyfin** | Deployment + PVC | Media server |
| **Mazanoke** | Deployment | Image compression |
| **MkDocs** | Deployment | Documentation site (this site) |
| **n8n** | Deployment + PVC | Workflow automation |
| **ntfy** | Deployment + PVC | Push notifications broker |
| **Paperless-ngx** | Deployment + PVC | Document management with OCR |
| **Open WebUI** | Helm | Chat UI for LLMs (backed by llama.cpp) |
| **Renovate** | CronJob | Automated dependency updates |
| **Stirling PDF** | Deployment | PDF tools |
| **Uptime Kuma** | Deployment + PVC | Uptime monitoring |
| **WithJoy Exporter** | CronJob + Deployment | Daily WithJoy guest-list export to Google Sheets, with a manual-trigger web UI |
| **ZeroClaw** | Deployment + PVC | AI personal assistant (Telegram + Gemini) |
| **Home Assistant** | ExternalService | Runs on a separate host, exposed through cluster ingress |
| **Proxmox** | ExternalService | Hypervisor UI, exposed through cluster ingress |
| **TrueNAS** | ExternalService | NAS management UI, exposed through cluster ingress |
| **UniFi Controller** | ExternalService | Network controller, exposed through cluster ingress |

---

## License

> MIT - see `LICENSE`.
