<!-- docs/apps/adguardhome.md -->
# AdGuard Home

Local DNS resolver with built-in **DoH/DoT** and ad-blocking.

| Deploy type | Image | Storage |
|---|---|---|
| 3 × StatefulSet | `adguard/adguardhome:v0.107.78` | PVC `10 GiB` each |

* Acts as the upstream DNS for the entire network.
* Also serves **DoT** on port `853` and **DoH** on `443`.

## Redundancy

Three independent instances run in the `adguardhome` namespace, one per k3s
node. Each has its own LoadBalancer VIP, hostname, certificate and work PVC,
so any one of them can serve the whole LAN on its own.

| Instance | StatefulSet | VIP | Hostname |
|---|---|---|---|
| Primary | `adguardhome` | `${LAN_PREFIX}.2` | `dns.${DOMAIN}` |
| Secondary | `adguardhome-secondary` | `${LAN_PREFIX}.102` | `dns-secondary.${DOMAIN}` |
| Tertiary | `adguardhome-tertiary` | `${LAN_PREFIX}.103` | `dns-tertiary.${DOMAIN}` |

All three VIPs are handed to clients (router DHCP, and the Tailscale
`exit-node-dns` ProxyClass in
`infrastructure/tailscale-operator/connector/proxyclass.yaml`), so a single
instance going down is invisible to clients apart from one resolver timeout.

### Placement

Every pod template carries the shared label `app.kubernetes.io/name: adguardhome`
and a **soft** pod anti-affinity rule on `topologyKey: kubernetes.io/hostname`:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: adguardhome
```

With three pods and three nodes the scheduler reliably places one per node,
without hardcoding node names into Git. It is deliberately `preferred` rather
than `required`: the Services use `externalTrafficPolicy: Cluster`, so a pod
does not have to share a node with the node advertising its VIP — but a Service
with **zero** ready endpoints leaves its VIP blackholed. Under `required`, a
node reboot would strand that instance in `Pending` and one of the three
resolvers would time out for clients. Under `preferred`, the pod simply
relocates onto a surviving node and all three VIPs keep answering.

Note that the `descheduler` runs hourly with `LowNodeUtilization` and may evict
these pods to rebalance; the anti-affinity weighting re-spreads them on
rescheduling.

### Configuration

All three mount the **same** `adguardhome-config` ConfigMap, generated from
`data/AdGuardHome.yaml`. The only per-instance difference is `$TLS_SERVER_NAME`,
substituted by the `move-config` initContainer via `envsubst`. Because the
rendered config lands in an `emptyDir`, changes made in the web UI are
ephemeral — the file is always re-derived from Git on restart. Runtime state
that *is* meant to persist (filters, rewrites, clients) is propagated from the
primary to the other two by [AdGuard Sync](adguardhome-sync.md).

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