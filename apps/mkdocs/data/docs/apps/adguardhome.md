<!-- docs/apps/adguardhome.md -->
# AdGuard Home

Local DNS resolver with built-in **DoH/DoT** and ad-blocking.

| Deploy type | Image | Storage |
|---|---|---|
| Deployment | `adguard/adguardhome:v0.107.61` | PVC `10 GiB` |

* Exposed at `dns.${DOMAIN}` **and** on port `853` (DoT) internally.  
* Acts as the upstream DNS for the entire network.

## DNS Configuration

### Upstream DNS

| Upstream | Purpose |
|---|---|
| `[/cluster.local/]10.43.0.10` | Conditional forward — routes `*.cluster.local` queries to CoreDNS |
| `https://dns10.quad9.net/dns-query` | Primary encrypted upstream (Quad9) |
| `https://dns.adguard-dns.com/dns-query` | Secondary encrypted upstream (AdGuard DNS) |
| `https://cloudflare-dns.com/dns-query` | Tertiary encrypted upstream (Cloudflare) |

The `[/cluster.local/]` conditional upstream is required so that the
Tailscale exit node pod (which uses AdGuard as its DNS) can resolve
cluster-internal names like `kubernetes.default.svc.cluster.local`.
Without it the pod cannot reach the Kubernetes API and crashes.

All other queries are resolved in parallel across the three encrypted
upstreams (`upstream_mode: parallel`).

### Bootstrap DNS

Bootstrap servers (`9.9.9.10`, `149.112.112.10`) resolve the hostnames
of the DoH upstreams themselves. These must be plain IP addresses.

### Local Rewrites

Custom DNS rewrites map short hostnames to LAN IPs (e.g. `homeassistant`
→ `${MGMT_PREFIX}.52`, `router` → `${MGMT_PREFIX}.1`, `pve-01` → `${LAN_PREFIX}.21`).