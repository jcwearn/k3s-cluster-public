# DNS Monitoring

DNS reachability probes for the UDM Pro resolver and a public control, via
[blackbox_exporter](https://github.com/prometheus/blackbox_exporter).

## Why

Nothing in the cluster resolves LAN DNS any more. Every VLAN's DHCP hands out its gateway
address as the only nameserver, and the UDM Pro forwards over DoH to NextDNS; the tailnet's
global nameserver is NextDNS directly. That removes the cluster from the LAN's DNS path -- a
k3s outage is not a DNS outage -- but it also means the gateway resolver is the single thing
every LAN client depends on, and a resolver that is running but wedged pages nobody on its own.

Internal hostnames (`*.${DOMAIN}`) are **tailnet-only**: publicly they are CNAMEs to the
gateway's `.ts.net` name, which only MagicDNS can resolve. A LAN client with Tailscale off does
not reach them, by decision (2026-09-19, when AdGuard Home was retired). Inside the cluster,
CoreDNS rewrites them to the Envoy proxy.

## Architecture

```
Prometheus ──scrape /probe?target=…──▶ blackbox-exporter ──DNS query──▶ resolver
```

Prometheus does not talk to the resolvers directly. Each scrape target is passed to
blackbox_exporter as a `target` parameter, the exporter performs a real DNS query against it,
and the result comes back as `probe_success`. The relabel rules in `additionalScrapeConfigs`
are the standard blackbox pattern: the target is moved into `__param_target`, copied to
`instance` so alerts can name it, and `__address__` is then rewritten to the exporter itself.

## Module

| Module | Query | Used for |
|--------|-------|----------|
| `dns_public` | `cloudflare.com` (A) | UDM Pro, public control resolver |

`dns_public` asks a forwarding resolver to resolve something public, which is the right
question for something whose only job is to forward.

## Targets

| Target | Job | Module |
|--------|-----|--------|
| `${MGMT_PREFIX}.1` (UDM Pro) | `dns-forwarders` | `dns_public` |
| `9.9.9.9` (control) | `dns-forwarders` | `dns_public` |

The public resolver is there purely as a control. It is what makes a WAN problem
distinguishable from a DNS problem.

## Alert Rules

Defined in the `dns-health` group in `infrastructure/prometheus/helm.yaml`. Both route
through the existing Alertmanager → ntfy path, so they need no additional wiring.

| Alert | Condition | For | Severity |
|-------|-----------|-----|----------|
| `GatewayResolverDown` | UDM Pro failing | 5m | critical |
| `DnsEgressDown` | both forwarders failing | 10m | warning |

`GatewayResolverDown` is critical because there is no second resolver: when the gateway stops
answering, every LAN client has no DNS at all. The tailnet is unaffected -- it resolves through
NextDNS directly, not through the house.

`DnsEgressDown` is deliberately separate. Both forwarders failing together points at WAN or
inter-VLAN routing rather than at DNS.

## Verification

```bash
# Exporter is up
kubectl -n prometheus get deploy blackbox-exporter

# Probe the gateway by hand through the exporter
kubectl -n prometheus port-forward svc/blackbox-exporter-svc 9115:9115
curl "http://localhost:9115/probe?target=${MGMT_PREFIX}.1&module=dns_public"
# expect: probe_success 1

# The scrape job should show two targets
# Prometheus UI -> Status -> Targets -> dns-forwarders
```

## References

- [blackbox_exporter DNS probe configuration](https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md#dns_probe)
- [Prometheus](prometheus.md) — the stack these rules live in
