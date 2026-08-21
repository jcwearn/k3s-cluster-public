# EOL Monitoring

Watches the major-version support windows of everything this cluster runs, and pushes a
notification while there is still time to plan the upgrade.

The gap this closes is narrow but real. Renovate covers container images and Helm charts;
`ansible-update-linux` covers OS packages weekly. Neither has any notion of a *release* reaching
the end of its support window. Proxmox VE 8 went end of life on 2026-08-31 and the upgrade off it
landed on 2026-08-19 -- twelve days of margin, and only because somebody happened to open the PVE
web UI.

## Architecture

```
endoflife.date  --(HTTPS, every 6h)-->  eol-exporter  --(scrape, 5m)--> Prometheus
                                                                            |
   node_os_info -----------+                                                |
   kube_node_info ---------+--> already scraped ------------------------>  join
   pve_version_info -------+                                                |
                                                                            v
                                                             release-lifecycle rules
                                                                            |
                                                          Alertmanager --> ntfy (weekly repeat)
```

- **`eol-exporter`** publishes *only* the upstream catalogue -- one series per known release cycle
  per tracked product.
- **The versions in use are not gathered by the exporter.** They were already being scraped:
  `node_os_info` carries `id` and `version_id` for all six machines, `kube_node_info` carries
  `kubelet_version`, and `pve_version_info` had been emitted by `pve-exporter` all along without any
  rule or dashboard using it. Discovering them again in the exporter would mean a second source of
  truth and PVE credentials the pod has no other reason to hold.
- **The join happens in PromQL**, in the `eol:release_in_use` recording rule.

## What is tracked

| Product | Slug | Where the running version comes from |
|---------|------|--------------------------------------|
| Proxmox VE | `proxmox-ve` | `pve_version_info` (pve-exporter) |
| Debian | `debian` | `node_os_info{job="proxmox-nodes"}` -- the hypervisors |
| Ubuntu | `ubuntu` | `node_os_info{job="node-exporter"}` -- the k3s guests |
| Kubernetes | `kubernetes` | `kube_node_info` -- `kubelet_version`, with the `+k3s` suffix stripped |

Slugs must match an [endoflife.date](https://endoflife.date) product. There is no `k3s` product, so
`kubernetes` stands in for it and the recording rule reduces `v1.32.4+k3s1` to cycle `1.32`.

Tracking another product is a one-line edit to `EOL_PRODUCTS` in
`infrastructure/prometheus/eol-exporter.yaml` -- plus an arm in the recording rule if its running
version is not already scraped.

## What is not tracked, and why

**TrueNAS.** Deliberately absent, for three reasons -- the third is the one that matters.

1. **endoflife.date has no TrueNAS product.** None of `truenas`, `truenas-scale`, `truenas-core`
   or `freenas` exist; nothing in the 464-product catalogue matches. A pending upstream PR
   ([endoflife-date/endoflife.date#9230](https://github.com/endoflife-date/endoflife.date/pull/9230),
   open since 2025-12-29) would add it, covering 23.10 through 25.10. If it merges, this half
   becomes a one-word change to `EOL_PRODUCTS`.
2. **The running version is not scraped.** The `truenas` job reaches Prometheus through Netdata and
   the graphite-exporter, which publishes 115 metrics -- all cgroup, disk and ARC counters, no
   version anywhere. There is also no TrueNAS API credential in the cluster: `truenas-nfs` speaks
   plain NFS. Supplying one would mean a new SOPS secret hand-carried out of `truenas-infra`.
3. **iXsystems publishes no end-of-life dates.** The
   [software status page](https://www.truenas.com/docs/softwarestatus/) contains no occurrence of
   "EOL" or "End of Life" at all; the policy is simply that **the two most recent releases are
   maintained**. The pending PR reflects this -- only 24.10 carries a real date, while 24.04 and
   23.10 are a bare `eol: true`.

Point 3 is why solving points 1 and 2 would still not buy much. `ReleaseEndOfLife` is a boolean and
would work. `ReleaseEndOfLifeApproaching` -- the ninety-day warning, the alert this whole component
exists for -- **can never fire for TrueNAS**, because there is no forward-looking date to count down
from. No amount of work here creates one.

**The tripwire to watch instead.** As of 2026-08-20 this NAS runs **25.04 (Fangtooth)**. The newest
stable train is 25.10, and 26.0 was still at `BETA.3`. Under the two-newest rule 25.04 is currently
maintained -- but **when 26.0 ships, 25.04 leaves the window** and becomes unmaintained silently.
That is a release event, not a date, so nothing in this component can watch for it. Check it when a
TrueNAS upgrade is next considered.

**Checked 2026-08-21.** 25.04.2.6 is the final Fangtooth release (2025-10-30) and the train is in
Maintenance; 25.10.6 is what iX now recommends for Community Edition. The upgrade was evaluated and
planned -- see [Upgrading TrueNAS](../misc/truenas-upgrade.md). That is the manual check this
section says has to stand in for an alert, and it only happened because somebody thought to run it.
Re-check on the same terms when 26.0 ships.

The general shape of the missing check is "the running cycle is not among the N newest", which is
expressible from `eol_cycle_info` -- the exporter already publishes an entry for *every* cycle,
including ones newer than what is installed. It would work today for Proxmox VE, Debian and Ubuntu.
It is not implemented because none of them is close to that condition, and TrueNAS, the one product
that needs it, is the one whose version is not scraped.

## Metrics

| Metric | Meaning |
|--------|---------|
| `eol_cycle_info{product,cycle,label,latest}` | A release cycle known upstream |
| `eol_cycle_is_eol{product,cycle}` | 1 if past end of life |
| `eol_cycle_eol_timestamp_seconds{product,cycle}` | End-of-life date. **Absent when none is published** |
| `eol_fetch_success{product}` | 1 if the last poll succeeded |
| `eol_fetch_success_timestamp_seconds{product}` | Unix time of the last successful poll |
| `eol:release_in_use{product,cycle}` | Recording rule -- one series per release actually running |

Two behaviours worth knowing before reading a graph:

- **A missing end-of-life timestamp is not a bug.** Upstream publishes no date for Proxmox VE 9
  yet, so the series simply does not exist. Absence keeps `ReleaseEndOfLifeApproaching` from
  matching at all; any sentinel value would either be a lie or fire forever.
- **A failed poll keeps the last good catalogue** and flips `eol_fetch_success` to 0 rather than
  dropping series. An endoflife.date outage must not blank the catalogue and make every release in
  the stack look unknown.

## Alert Rules

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| `ReleaseEndOfLife` | A release in use is past end of life | 1h | critical |
| `ReleaseEndOfLifeApproaching` | End of life is 0-90 days away | 1h | warning |
| `ReleaseNotInEolCatalog` | A release in use has no catalogue entry | 6h | warning |
| `EolCatalogStale` | No successful poll for a product in 48h | 1h | warning |
| `EolCatalogMissing` | A product has never polled successfully | 1h | warning |

The last three are the ones that keep the check itself honest. A silent poller is no better than no
poller: without them, a renamed slug or an unreachable API would make the first two alerts go quiet,
which looks exactly like everything being supported.

`Release*` and `Eol*` alerts route to ntfy with a **168h repeat interval** rather than the global
12h. An end-of-life release is a standing condition, not an incident -- at 12h a 90-day warning
window is roughly 180 pushes, which is how a real signal gets tuned out.

## Dashboard

**Grafana -> Lifecycle -> Release Lifecycle.** One table: product, cycle in use, latest in that
cycle, and days until end of life. A blank countdown means no date is published yet; a negative one
means the release is already past it.

## Cluster-Side Configuration

| File | Contents |
|------|----------|
| `infrastructure/prometheus/data/eol_exporter.py` | The poller itself -- a real Python file, not a YAML block scalar |
| `infrastructure/prometheus/eol-exporter.yaml` | Deployment and Service |
| `infrastructure/prometheus/kustomization.yaml` | `configMapGenerator` that turns the script into a ConfigMap |
| `infrastructure/prometheus/eol-dashboard.yaml` | Grafana dashboard ConfigMap |
| `infrastructure/prometheus/helm.yaml` | `job_name: eol` scrape config, `release-lifecycle` rule group, Alertmanager route |

There is **no** host-side configuration and **no** secret. The exporter needs only outbound HTTPS.

## Verification

```bash
P=/api/v1/namespaces/prometheus/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1

# 1. The exporter is up and has a catalogue
kubectl get pods -n prometheus -l app=eol-exporter
kubectl logs -n prometheus -l app=eol-exporter    # one "fetched <product>: N cycles" per product

# 2. Prometheus is scraping it
kubectl get --raw "$P/query?query=up%7Bjob%3D%22eol%22%7D"

# 3. The join produces one row per release actually running
kubectl get --raw "$P/query?query=eol%3Arelease_in_use"

# 4. The rules are evaluating, not merely applied
kubectl get --raw "$P/rules" | grep -o 'release-lifecycle'
```

Step 4 matters more than it looks. A rule that was never selected and a rule whose condition is
false are indistinguishable from the outside -- both are simply quiet.

## Editing the poller

Edit `data/eol_exporter.py` directly. It is pulled in by the `configMapGenerator` in
`kustomization.yaml`, which appends a hash of the content to the ConfigMap name; kustomize rewrites
the Deployment's volume reference to match, so any change to the script rolls the pod by itself.
There is no reloader annotation and nothing to reload in place -- the script is read once at start.

It runs non-root with a read-only root filesystem and uses only the Python standard library, so the
stock `python:3.13-alpine` image runs it with no build step and no install at start.

> **Careful:** this path has Flux `postBuild` substitution. A braced `$${...}` anywhere in the script
> or the dashboard JSON is silently replaced with an empty string. The script contains none -- keep
> it that way, and reference the Grafana datasource by its `prometheus` uid rather than a dashboard
> variable.

## References

- [endoflife.date](https://endoflife.date) -- the upstream catalogue
- [endoflife.date API v1](https://endoflife.date/docs/api/v1/) -- `/api/v1/products/<slug>/`
- [Proxmox VE FAQ](https://pve.proxmox.com/wiki/FAQ) -- the PVE support-lifecycle table
- [Kubernetes release history](https://kubernetes.io/releases/) -- upstream support windows
