# Immich

[Immich](https://immich.app/) is a **self-hosted photo and video backup solution** directly from your mobile phone. It's a high-performance, privacy-focused alternative to Google Photos.

| Setting            | Value                              |
|--------------------|------------------------------------|
| **URL**            | `https://immich.${DOMAIN}`         |
| **Chart**          | `immich` v0.10.1                   |
| **Image**          | `immich/immich:v2.2.3`             |
| **Database**       | PostgreSQL (CloudNativePG)         |
| **Storage**        | PVC `immich-library`                |
| **Ingress class**  | `nginx` (TLS via cert-manager)     |
| **Namespace**      | `immich`                            |

## Architecture

* **Main controller** - Handles API requests, file uploads, and metadata management
* **Machine learning** - Optional ML service for face recognition, object detection, and smart search
* **Valkey** - Redis-compatible cache layer for improved performance
* **PostgreSQL** - Database with vector extensions (vchord) for similarity search

## Features

* **Mobile apps** - Native iOS and Android apps for automatic backup
* **Face recognition** - AI-powered face detection and grouping
* **Smart search** - Search by objects, people, or location
* **Map view** - Visualize photos by location on an interactive map
* **Shared albums** - Collaborate with family and friends
* **Video support** - Full video playback and transcoding

## Storage

The library is stored in a persistent volume claim (`immich-library`) mounted at the library path. Ensure adequate storage for your photo/video collection.

## Database

Uses CloudNativePG with vector extensions enabled:
* `vchord` - Vector similarity search for image embeddings
* `earthdistance` - Geographic distance calculations

---

## Database backups

`immich-database` is backed up nightly at 02:45 to Cloudflare R2 with continuous WAL archiving —
see [Postgres Backups](../infrastructure/postgres-backups.md).

Restoring it requires pinning the **same** `cloudnative-vectorchord` image. A recovery bootstrap
replays the data directory rather than running `initdb`, so `postInitApplicationSQL` never fires:
`vchord` returns with the data and needs binaries that match it. Restored onto a stock postgres
image, the cluster will not start.

This covers the database only. The photo and video library on NFS is **not** backed up.

---

> **TODO** – Document library backup strategy, storage sizing, and ML model configuration.
