# Application Workloads

This section covers every service the cluster actually **runs** or
**proxies** for day-to-day use.  Think of it as the “user-facing” half
of the stack.

| App | Purpose | Docs |
|-----|---------|------|
| **Ansible** | Automated server updates via CronJob-driven Ansible playbooks. | [Read more](ansible.md) |
| **AdGuard Home** | Network-wide DNS resolver with ad-blocking and DoT/DoH. | [Read more](adguardhome.md) |
| **AdGuard Sync** | Tool for synchronizing AdGuardHome config to replica instances.  | [Read more](adguardhome-sync.md) |
| **Home Assistant** | Home-automation hub (runs off-cluster, proxied via Ingress). | [Read more](homeassistant.md) |
| **Homepage** | Service dashboard & link hub. | [Read more](homepage.md) |
| **Immich** | Self-hosted photo and video backup solution with AI features. | [Read more](immich.md) |
| **It-Tools** | IT Tools is a collection of tools for IT professionals | [Read more](it-tools.md) |
| **UniFi Controller** | Manages network gear; exposed securely through the cluster. | [Read more](unifi.md) |
| **Headlamp** | Extensible K8s web UI (replaces archived kubernetes-dashboard). | [Read more](headlamp.md) |
| **Mazanoke** | Self-hosted image optimizer / converter | [Read more](mazanoke.md) |
| **MkDocs** | Generates this documentation site (built by CI). | [Read more](mkdocs.md) |
| **n8n** | Workflow automation platform for connecting apps and services. | [Read more](n8n.md) |
| **ntfy** | Lightweight push-notification broker (Web + WebSocket). | [Read more](ntfy.md) |
| **Paperless-ngx** | Document management system with OCR, tagging, and full-text search. | [Read more](paperless-ngx.md) |
| **Open WebUI** | Web interface for LLM interactions via OpenAI-compatible API | [Read more](open-webui.md) |
| **Renovate** | Cron-driven bot that keeps Helm charts & images up to date. | [Read more](renovate.md) |
| **Stirling Pdf** | A privacy-first, self-hosted PDF toolbox | [Read more](stirling-pdf.md) |
| **Uptime Kuma** | A self-hosted, open-source uptime monitoring and alerting system | [Read more](uptime-kuma.md) |
| **Ebooks** | Self-hosted ebook management stack (Shelfmark + Calibre-Web + VPN). | [Read more](ebooks.md) |
| **WithJoy Exporter** | Daily CronJob that exports the WithJoy guest list to a Google Sheet, plus a manual-trigger web UI. | [Read more](withjoy-exporter.md) |
| **hivemind** | Party game: one snake steered by the whole room, over server-sent events. | [Read more](hivemind.md) |
| **World Clock** | Multi-timezone clock dashboard with hypothetical-time conversion for wedding planning. | [Read more](world-clock.md) |
| **ZeroClaw** | Lightweight AI personal assistant daemon connecting Telegram to Gemini LLM. | [Read more](zeroclaw.md) |

---

## Deployment style

* **Namespaces:** Each app lives in its own namespace for tidy RBAC and
  resource quotas.
* **Kustomize layers:** Manifests are grouped under  
  `clusters/prod/apps/` with a top-level `kustomization.yaml`.
* **Ingress:** All public URLs use Envoy Gateway HTTPRoutes,
  secured by the wildcard `${DOMAIN}` certificate on the shared
  Gateway (issued by cert-manager).
* **Tailscale exposure:** Add `tailscale.com/expose: "true"` to any
  Service for Tailnet-only access.

> **Next steps:** Flesh out each app page with environment variables,
> PV sizes, backup schedules, upgrade notes, and dashboards.