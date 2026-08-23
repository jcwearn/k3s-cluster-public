# job-track

[job-track](https://github.com/jcwearn/job-track) is a **job search tracker** — a
pipeline board, a filterable lead table, and a per-lead page with an append-only
timeline and tasks. A single Go binary with templ and HTMX over Postgres.

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| **URL**            | `https://job-track.${DOMAIN}`             |
| **Image**          | `ghcr.io/jcwearn/job-track`               |
| **Database**       | PostgreSQL 16 (CloudNative-PG)            |
| **Storage**        | None — all state is in Postgres           |
| **Ingress**        | Envoy Gateway HTTPRoute                   |
| **Namespace**      | `job-track`                               |

## Access

* **Public URL**: `https://job-track.${DOMAIN}` (via Envoy Gateway with TLS)
* **Tailscale**: `job-track` hostname on the Tailnet
* **LoadBalancer IP**: `${LAN_PREFIX}.36` (via kube-vip)

The hostname is a public DNS record but not a public service. The `Gateway`
carries `external-dns.alpha.kubernetes.io/target: k3s-gateway.${TAILNET}`, so
external-dns writes every route's hostname as a CNAME to the tailnet name —
anyone can resolve `job-track.${DOMAIN}`, only the tailnet can reach it.

!!! note "What holds that property"

    That single annotation on the `Gateway`, not anything in this app. Pointed
    at a routable address it would expose every app behind the gateway at once.

    Most of those ship their own login — n8n, Immich, Paperless and Jellyfin all
    authenticate — so they would degrade to "protected by a password". job-track
    has no login, and the database behind it holds compensation figures,
    negotiation positions, recruiter contact details and, once Gmail ingestion
    lands, a mail provider OAuth refresh token. It would degrade to open.

    If that annotation ever changes, an Envoy `SecurityPolicy` on this route
    needs to land in the same commit.

## Architecture

* **Migrations run in an init container** — the same image with `-migrate`. Not
  at startup, so that raising `replicas` later cannot have two processes race
  each other through the same migration.
* **PostgreSQL backend** — a CloudNative-PG `Cluster` (`job-track-database`),
  backed up nightly at 02:30 to Cloudflare R2 with continuous WAL archiving. See
  [Postgres Backups](../infrastructure/postgres-backups.md) for the restore
  runbook.
* **No persistent volume** — every asset (stylesheet, htmx, icon) and every SQL
  migration is embedded in the binary, so the image is the whole installation.
* **Timezone** — the container runs `America/New_York`. Due dates are human
  dates typed into a date field, and under UTC "due Friday" renders as Thursday
  all evening.

## Probes

* **Liveness** (`/healthz`) deliberately does not touch the database. A database
  outage is not something a pod restart fixes, and wiring it in turns one into a
  crash loop.
* **Readiness** (`/readyz`) does, which takes the pod out of the Service while
  leaving it running.

## Criteria

Search criteria — a compensation floor, preferred cities, title exclusions, a
preferred stack — are **not** in this repo or in the application's. They live in
a `settings` table and are edited at `/settings` in the UI. That is deliberate:
this repo is publicly mirrored, and a salary target does not belong in it.

The migration seeds one empty row, which applies no rules at all until you fill
it in.

## Seeding

Leads can be bulk-imported from JSON rather than retyped. Applying a seed is
idempotent — leads and tasks that already exist are left alone:

```bash
kubectl -n job-track port-forward deploy/job-track 8080:8080
# then, from a checkout of jcwearn/job-track:
JOBTRACK_DATABASE_URL=... job-track -seed path/to/leads.json
```

The seed file is not baked into the image. `seed/example.json` in the
application repo shows the shape; a real one holds recruiter names and
compensation figures and should stay off GitHub.

## Resources

* **CPU**: 10m (request) to 500m (limit)
* **Memory**: 32Mi (request) to 256Mi (limit)
