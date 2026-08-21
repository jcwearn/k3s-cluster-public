# n8n

[n8n](https://n8n.io/) is a **workflow automation platform** that lets you connect apps and services with visual, node-based workflows. It supports hundreds of integrations and can be extended with custom code nodes.

| Setting            | Value                                |
|--------------------|--------------------------------------|
| **URL**            | `https://n8n.${DOMAIN}`              |
| **Image**          | `n8nio/n8n:2.8.3`                    |
| **Database**       | PostgreSQL 16 (CloudNative-PG)       |
| **Storage**        | PVC `n8n-data` (1Gi, RWX)           |
| **Ingress**        | Envoy Gateway HTTPRoute              |
| **Namespace**      | `n8n`                                |

## Architecture

* **PostgreSQL backend** — Uses a CloudNative-PG `Cluster` (`n8n-database`) instead of the default SQLite. Backed up nightly at 02:00 to Cloudflare R2 with continuous WAL archiving; see [Postgres Backups](../infrastructure/postgres-backups.md) for the restore runbook.
* **Encryption key** — All stored credentials are encrypted with `N8N_ENCRYPTION_KEY` (SOPS-encrypted in Git). Loss of this key makes saved credentials unrecoverable.
* **Persistent volume** — `/home/node/.n8n` is backed by an NFS PVC for binary data and local cache.

## Access

* **Public URL**: `https://n8n.${DOMAIN}` (via Envoy Gateway with TLS)
* **Tailscale**: `n8n` hostname on the Tailnet
* **LoadBalancer IP**: `${LAN_PREFIX}.31` (via kube-vip)

## Resources

* **CPU**: 250m (request) to 1 core (limit)
* **Memory**: 256Mi (request) to 1Gi (limit)

## Notes

* The n8n pod may briefly crash-loop on first deploy while CNPG provisions the database — this self-resolves.
* External webhooks (from GitHub, Slack, etc.) require Tailscale funnel configuration since DNS resolves through Tailscale. Internal cluster webhooks work fine.

---

> **TODO** — Document webhook configuration, backup strategy for workflow exports, and common workflow examples.
