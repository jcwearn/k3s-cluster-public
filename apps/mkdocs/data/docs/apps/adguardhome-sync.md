# AdGuard Home Sync

[`adguardhome-sync`](https://github.com/bakito/adguardhomegsync) keeps multiple
AdGuard Home instances **perfectly in-sync** — same filters, same DHCP leases,
same custom rules.

| Setting / Resource | Value |
|--------------------|-------|
| **Type**           | Kubernetes `CronJob` |
| **Image**          | `ghcr.io/bakito/adguardhome-sync:v0.9.2` |
| **Schedule**       | `0 * * * *` — hourly |
| **Namespace**      | `adguardhome` |
| **Secret**         | `adguardhome-secrets` |

### How it works

1. **Init-container** substitutes secrets into `adguardhome-sync.yaml`  
   (`envsubst` → `/config-target`).
2. Main container runs sync once, then the Job finishes.
3. Kubernetes starts a fresh Job at the top of every hour.

### Topology

The primary is the origin; the other two [AdGuard Home](adguardhome.md)
instances are replicas. Each is addressed over its LoadBalancer VIP on the
HTTPS port `10443`.

| Role | Instance | Config keys |
|---|---|---|
| Origin | `adguardhome` | `ORIGIN_URL`, `ORIGIN_USERNAME`, `ORIGIN_PASSWORD` |
| Replica | `adguardhome-secondary` | `REPLICA1_URL`, `REPLICA1_USERNAME`, `REPLICA1_PASSWORD` |
| Replica | `adguardhome-tertiary` | `REPLICA2_URL`, `REPLICA2_USERNAME`, `REPLICA2_PASSWORD` |

The replica list lives in `apps/adguardhome/data/adguardhome-sync.yaml`; the URLs
and credentials live in the SOPS-encrypted `adguardhome-secrets`. Adding a fourth
instance means appending a `REPLICA3_*` block to both.
