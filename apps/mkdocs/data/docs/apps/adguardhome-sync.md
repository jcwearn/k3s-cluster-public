# AdGuard Home Sync

[`adguardhome-sync`](https://github.com/bakito/adguardhomegsync) keeps multiple
AdGuard Home instances **perfectly in-sync** — same filters, same DHCP leases,
same custom rules.

| Setting / Resource | Value |
|--------------------|-------|
| **Type**           | Kubernetes `CronJob` |
| **Image**          | `ghcr.io/bakito/adguardhome-sync:v0.7.5` |
| **Schedule**       | `0 * * * *` — hourly |
| **Namespace**      | `adguardhome-sync` |

### How it works

1. **Init-container** substitutes secrets into `adguardhome-sync.yaml`  
   (`envsubst` → `/config-target`).
2. Main container runs sync once, then the Job finishes.
3. Kubernetes starts a fresh Job at the top of every hour.

### TODO — Secrets

* [ ] Populate `adguardhome-sync-secrets` with `SOURCE_USERNAME`,
      `SOURCE_PASSWORD`, `TARGET_USERNAME`, `TARGET_PASSWORD`.
* [ ] Add a second target block if you bring a third AdGuard Home node online.