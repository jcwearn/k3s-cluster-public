# DNS Monitoring

DNS reachability probes for the AdGuard Home resolvers and for the resolvers they fall back
to, via [blackbox_exporter](https://github.com/prometheus/blackbox_exporter).

## Why

Before this existed, nothing in the cluster alerted on DNS. An AdGuard outage surfaced only as
the generic `KubernetesPodNotHealthy` rule after 10 minutes, and only if the pods actually
entered a bad phase. A resolver that was running but wedged kept its Service endpoint, so its
LoadBalancer VIP carried on advertising and silently blackholed every query sent to it — the
precise failure mode that running three instances is supposed to protect against.

## Architecture

```
Prometheus ──scrape /probe?target=…──▶ blackbox-exporter ──DNS query──▶ resolver
```

Prometheus does not talk to the resolvers directly. Each scrape target is passed to
blackbox_exporter as a `target` parameter, the exporter performs a real DNS query against it,
and the result comes back as `probe_success`. The relabel rules in `additionalScrapeConfigs`
are the standard blackbox pattern: the target is moved into `__param_target`, copied to
`instance` so alerts can name it, and `__address__` is then rewritten to the exporter itself.

## Modules

Two modules, because the two groups of targets need different questions asked of them.

| Module | Query | Used for |
|--------|-------|----------|
| `dns_local_rewrite` | `router` (A) | The three AdGuard instances |
| `dns_public` | `cloudflare.com` (A) | UDM Pro fallback, public control resolver |

`dns_local_rewrite` queries **a rewrite, not a real domain**, and this is deliberate. A rewrite
is answered from AdGuard's own config with no upstream involved, so the probe stays green
through an ISP outage and goes red only when the resolver itself has stopped answering.
Probing a public name would conflate "AdGuard is broken" with "the internet is unreachable"
and page for the wrong thing — and worse, would go red on all three instances simultaneously
during a WAN outage.

This means the probe depends on at least one rewrite existing in
`apps/adguardhome/data/AdGuardHome.yaml`. If the `router` rewrite is ever removed, point the
module at another one.

`dns_public` asks a forwarding resolver to resolve something public, which is the right
question for something whose only job is to forward.

## Targets

| Target | Job | Module |
|--------|-----|--------|
| `${LAN_PREFIX}.2` | `dns-adguard` | `dns_local_rewrite` |
| `${LAN_PREFIX}.102` | `dns-adguard` | `dns_local_rewrite` |
| `${LAN_PREFIX}.103` | `dns-adguard` | `dns_local_rewrite` |
| `${MGMT_PREFIX}.1` (UDM Pro) | `dns-forwarders` | `dns_public` |
| `9.9.9.9` (control) | `dns-forwarders` | `dns_public` |

The public resolver is there purely as a control. It is what makes a WAN problem
distinguishable from a DNS problem.

## Alert Rules

Defined in the `dns-health` group in `infrastructure/prometheus/helm.yaml`. All of them route
through the existing Alertmanager → ntfy path, so they need no additional wiring.

| Alert | Condition | For | Severity |
|-------|-----------|-----|----------|
| `AdGuardInstanceDown` | one instance failing | 5m | warning |
| `AdGuardAllDown` | every instance failing | 2m | critical |
| `FallbackResolverDown` | UDM Pro failing | 15m | warning |
| `DnsEgressDown` | both forwarders failing | 10m | warning |

`AdGuardInstanceDown` is the one that earns its keep. A single instance failing is invisible to
clients, because the other two keep answering — so without an alert it decays unnoticed until
the remaining instances follow it down and the outage arrives all at once.

`FallbackResolverDown` exists for the same reason in reverse: a fallback path that has quietly
stopped working is discovered only at the moment it is needed, which is the worst possible time
to discover it.

`DnsEgressDown` is deliberately separate from the AdGuard alerts. Both forwarders failing
together points at WAN or inter-VLAN routing rather than at DNS.

## Verification

```bash
# Exporter is up
kubectl -n prometheus get deploy blackbox-exporter

# Probe a resolver by hand through the exporter
kubectl -n prometheus port-forward svc/blackbox-exporter-svc 9115:9115
curl "http://localhost:9115/probe?target=${LAN_PREFIX}.2&module=dns_local_rewrite"
# expect: probe_success 1

# Both scrape jobs should show three and two targets respectively
# Prometheus UI -> Status -> Targets -> dns-adguard / dns-forwarders
```

To test the alerting path end to end, scale one instance down and wait for the ntfy push:

```bash
kubectl -n adguardhome scale statefulset adguardhome-secondary --replicas=0
# ... expect AdGuardInstanceDown after 5m, then restore:
kubectl -n adguardhome scale statefulset adguardhome-secondary --replicas=1
```

## References

- [blackbox_exporter DNS probe configuration](https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md#dns_probe)
- [AdGuard Home](../apps/adguardhome.md) — the resolvers being probed
- [Prometheus](prometheus.md) — the stack these rules live in
