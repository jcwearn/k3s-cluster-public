# Tailscale Operator

The **Tailscale Kubernetes Operator** makes any Service reachable
on your Tailnet without exposing it to the open Internet.

* **Version:** `1.82.0`
* **Auth:** OAuth client ID/secret injected from `tailscale-oauth` secret.
* **Mode:** `allowAllNamespaces=true` so *any* workload can opt-in
  by adding `tailscale.com/expose: "true"` plus an optional
  `tailscale.com/hostname`.

Example (Envoy Gateway proxy):

```yaml
annotations:
  tailscale.com/expose: "true"
  tailscale.com/hostname: "k3s-gateway"
```

## Exit Node

A Tailscale **Connector** advertises the cluster as an exit node so
remote clients can route all traffic through the homelab.

### DNS (ProxyClass `exit-node-dns`)

The exit node pod uses a custom `ProxyClass` that overrides DNS to solve
a routing problem: CoreDNS rewrites `*.${DOMAIN}` to the Envoy proxy
ClusterIP, which is unreachable from outside the cluster.
By pointing the pod at AdGuard Home instead, exit node clients get
routable answers (a CNAME to the Tailscale hostname `k3s-gateway.${TAILNET}`).

```yaml
dnsPolicy: "None"
dnsConfig:
  nameservers:
    - "${LAN_PREFIX}.2"    # AdGuard Home
    - "${LAN_PREFIX}.102"  # Fallback
  searches:
    - "tailscale.svc.cluster.local"
    - "svc.cluster.local"
    - "cluster.local"
  options:
    - name: ndots
      value: "5"
```

| Setting | Why |
|---|---|
| `dnsPolicy: None` | Bypasses CoreDNS so `*.${DOMAIN}` resolves via upstream DNS instead of the in-cluster rewrite |
| Nameservers → AdGuard | Returns routable CNAME answers for `*.${DOMAIN}` via MagicDNS |
| Search domains + `ndots: 5` | Allows the pod to resolve short cluster names (e.g. `kubernetes.default.svc` → `kubernetes.default.svc.cluster.local`) |

AdGuard has a matching conditional upstream (`[/cluster.local/]10.43.0.10`)
that forwards `*.cluster.local` queries back to CoreDNS, completing the
loop so both external and internal DNS resolution work.