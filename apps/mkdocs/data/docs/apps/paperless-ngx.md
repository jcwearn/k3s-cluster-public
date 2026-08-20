# Paperless-ngx

[Paperless-ngx](https://docs.paperless-ngx.com/) is a **document management system** that transforms physical documents into a searchable online archive. It features OCR, automatic tagging, full-text search, and a modern web interface.

| Setting            | Value                                |
|--------------------|--------------------------------------|
| **URL**            | `https://paperless.${DOMAIN}`        |
| **Image**          | `ghcr.io/paperless-ngx/paperless-ngx:2.14.7` |
| **Database**       | PostgreSQL 16 (CloudNative-PG)       |
| **Storage**        | 3 PVCs: data (2Gi), media (8Gi), consume (1Gi) |
| **Ingress**        | Envoy Gateway HTTPRoute              |
| **Namespace**      | `paperless-ngx`                      |

## Architecture

* **PostgreSQL backend** — Uses a CloudNative-PG `Cluster` (`paperless-ngx-database`) for reliable document metadata storage. Backed up nightly at 02:30 to Cloudflare R2 with continuous WAL archiving; see [Postgres Backups](../infrastructure/postgres-backups.md). Note the cluster is `paperless-ngx-database` but the database inside it is `paperless`.
* **Redis sidecar** — A `redis:7-alpine` container runs as a sidecar in the same pod, providing the message broker and caching layer Paperless-ngx requires. Connects via `redis://localhost:6379`.
* **Three PVCs** — Storage is split into `data` (config/thumbnails), `media` (original and archived documents), and `consume` (transient inbox for new documents).
* **OCR** — Tesseract runs inside the container for automatic text recognition. Memory limit is set to 4Gi to accommodate OCR processing spikes.

## Access

* **Public URL**: `https://paperless.${DOMAIN}` (via Envoy Gateway with TLS)
* **Tailscale**: `paperless` hostname on the Tailnet
* **LoadBalancer IP**: `${LAN_PREFIX}.33` (via kube-vip)

## Resources

* **Paperless-ngx**: 500m–2 CPU, 512Mi–4Gi memory
* **Redis sidecar**: 100m–250m CPU, 64Mi–256Mi memory

## Initial Setup

After deployment, create an admin user:

```bash
kubectl -n paperless-ngx exec -it deploy/paperless-ngx -c paperless-ngx -- python3 manage.py createsuperuser
```

## Notes

* The pod may briefly crash-loop on first deploy while CNPG provisions the database — this self-resolves.
* Documents placed in the `consume` directory (`/usr/src/paperless/consume`) are automatically ingested and removed.
* The `PAPERLESS_SECRET_KEY` is used for session signing and token generation. Loss of this key invalidates all active sessions.
