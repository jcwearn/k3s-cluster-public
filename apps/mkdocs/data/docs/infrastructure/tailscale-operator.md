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

The exit node pod uses a custom `ProxyClass` that gives it public resolvers
and nothing else. The pod resolves one name that matters,
`controlplane.tailscale.com`, and losing DNS must not cost remote access:
a cluster resolver would put the exit node and the subnet router behind
the cluster's own DNS, and a LAN address would put them behind the gateway.
Tailnet clients do not resolve through this pod -- they use the tailnet's
global nameserver (NextDNS) -- so nothing here needs to answer `*.${DOMAIN}`.

```yaml
dnsPolicy: "None"
dnsConfig:
  nameservers:
    - "9.9.9.9"
    - "1.1.1.1"
    - "1.0.0.1"
  searches:
    - "tailscale.svc.cluster.local"
    - "svc.cluster.local"
    - "cluster.local"
  options:
    - name: ndots
      value: "5"
    - name: timeout
      value: "2"
    - name: attempts
      value: "2"
```

| Setting | Why |
|---|---|
| `dnsPolicy: None` | Bypasses CoreDNS entirely; the pod's DNS does not depend on the cluster |
| Three public nameservers | glibc honours at most three (`MAXNS`); all public so neither a cluster nor a LAN fault takes the exit node down |
| Search domains + `ndots: 5` | Kept for short cluster names, though the public resolvers cannot answer them -- the pod has no reason to look any up |
| `timeout: 2`, `attempts: 2` | Fail over to the next resolver quickly rather than hanging on one |
