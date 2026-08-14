# Uptime Kuma

[Uptime Kuma](https://github.com/louislam/uptime-kuma) provides a slick status page and
alerting layer for HTTP, TCP, ICMP, and custom probes—think “self-hosted
BetterUptime.”

| Setting            | Value                                |
|--------------------|--------------------------------------|
| **URL**            | `https://uptime.${DOMAIN}`           |
| **Image**          | `louislam/uptime-kuma:1` (rootless) |
| **Storage**        | PVC `1 GiB` (SQLite)                |
| **Ingress class**  | `nginx` (TLS via cert manager)       |
| **Namespace**      | `uptime-kuma`                        |

## Why it matters

* **Early warning** - catch outages in homelab services, public endpoints, and
  Tailnet IPs.
* **One dashboard** - main landing page for operational visibility.
* **Free & flexible** - unlimited monitors and integrations (Email, ntfy, Discord, Slack, etc.).

---

## TODO — Secrets & notifications

* [ ] **Add ntfy credentials** for push alerts.
* [ ] **Create SMTP Secret** (`smtp-credentials`) for email notifications.
* [ ] **Webhook tokens** for Discord / Slack channels.
* [ ] Configure backup job to off cluster object storage.

> After adding the Secrets, mount them via `envFrom:` or individual
> `env:` keys in the Deployment so Uptime Kuma can pick them up
> without rebuilding the container image.