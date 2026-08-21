# k3s-cluster Homelab

Welcome to **`k3s-cluster`** - the GitOps repository that declaratively manages my three-node **k3s** Kubernetes homelab, running as virtual machines on Proxmox VE.

---

## Why this repo exists

* **Reproducible** - every manifest lives in Git; a fresh cluster can be bootstrapped with one FluxCD command.
* **Minimal yet useful** - only the add-ons I actually need to self-host services for my home network.
* **Secure** - secrets encrypted with SOPS + `age`; services exposed only through Tailscale, Cloudflare DNS, or Envoy Gateway with Let's Encrypt.

---

## Hardware snapshot

There are **two layers**, and it is worth keeping them apart. Three Beelink SER8 mini-PCs run
Proxmox VE; each hosts exactly one k3s node as a guest. `k3s-01/02/03` are virtual machines, not
the hardware they run on.

### Hypervisors — `pve-01`, `pve-02`, `pve-03`

| | |
|---|---|
| Hardware | Beelink SER8 — 8 core / 16 thread, 32 GiB RAM, 1 TB NVMe |
| Hypervisor | Proxmox VE 9.2 |
| Storage | `local` (~94 GiB, directory) + `local-lvm` (~794 GiB LVM-thin) |
| Clustering | Three-node PVE cluster. **No Ceph and no shared storage** |

Because storage is local to each host, moving a guest means copying its disk rather than a fast
live migration. Plan hypervisor work around that: drain the k3s node and shut the VM down, do not
expect to migrate it away.

### Guests

| VM | VMID | Host | vCPU / RAM | Disk | OS |
|----|------|------|-----------|------|-----|
| `k3s-01` | 100 | `pve-01` | 16 / 32 GiB | 500 GiB on `local-lvm` | Ubuntu 24.04 LTS |
| `k3s-02` | 201 | `pve-02` | 16 / 32 GiB | 500 GiB on `local-lvm` | Ubuntu 24.04 LTS |
| `k3s-03` | 301 | `pve-03` | 16 / 32 GiB | 500 GiB on `local-lvm` | Ubuntu 24.04 LTS |

RAM is ballooned, so each guest sees roughly 28 GiB of its configured 32 GiB. Each host also
carries a stopped `ubuntu-cloud` cloud-init template (VMIDs 5000 / 6000 / 7000), which is not part
of the cluster.

---

## Repository layout

```text
.
├── apps/
│   ├── adguardhome/        # DNS resolver & ad blocker
│   ├── ansible/            # Ansible Runner CronJobs (infra automation)
│   ├── ebooks/             # E-book library (Calibre-Web + Calibre)
│   ├── headlamp/           # Kubernetes dashboard
│   ├── hivemind/           # Party game (one snake, everybody steers)
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
│   ├── csi-driver-nfs/     # NFS CSI driver + StorageClasses
│   ├── envoy-gateway/      # Gateway API ingress (Envoy proxy)
│   ├── external-dns/       # DNS record sync to Cloudflare
│   ├── flux-operator/      # Flux Operator + FluxInstance + webhook receiver
│   ├── kube-vip/           # HA virtual IP for control plane + LoadBalancer
│   ├── llama-cpp/          # Local LLM inference server (Qwen3, CPU)
│   ├── prometheus/         # Monitoring stack (kube-prometheus-stack + TrueNAS/Proxmox monitoring)
│   ├── reloader/           # Auto-restart on ConfigMap/Secret changes
│   ├── system-upgrade-controller/ # Declarative k3s node upgrades
│   └── tailscale-operator/ # Private VPN overlay
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
| | **System Upgrade Controller** | Upgrades k3s on the nodes from a pinned Plan in Git |

---

## Workloads

| App | Type | Notes |
|-----|------|-------|
| **AdGuard Home** | 3 × StatefulSet + PVC | Local DNS / DoH / DoT resolver (one per node) |
| **Ansible Runner** | CronJob | Automated infrastructure management |
| **Ebooks** | Deployment + PVC | Calibre-Web + Calibre e-book library |
| **Headlamp** | Deployment | Kubernetes dashboard |
| **hivemind** | Deployment | Party game; single replica, in-memory rooms |
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
