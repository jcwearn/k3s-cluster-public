# k3s homelab

A GitOps-managed Kubernetes homelab: three-node k3s HA cluster, FluxCD reconciling every
manifest in this repository to cluster state on a ten-minute loop. There is no imperative
step anywhere in the workflow — a change is a pull request, and merging it is the deploy.

This is a filtered public mirror of a private repository. It is complete, in the sense that
everything the cluster runs is here; what has been removed is addresses, not architecture.

## What is in here

| | |
| --- | --- |
| **Ingress** | Envoy Gateway (Gateway API), one shared Gateway, wildcard TLS from cert-manager via Let's Encrypt DNS-01 |
| **DNS** | external-dns syncing records to Cloudflare, CoreDNS split-horizon so in-cluster pods resolve the same hostnames internally, AdGuard Home as the LAN resolver |
| **Storage** | NFS-backed dynamic provisioning from a TrueNAS server, CloudNativePG for Postgres |
| **Networking** | kube-vip for the control-plane VIP and LoadBalancer addresses, Tailscale operator for private access |
| **Observability** | kube-prometheus-stack, with Proxmox and TrueNAS metrics fed in through a graphite exporter |
| **Secrets** | SOPS + age, decrypted by Flux at reconcile time; no plaintext secret has ever been committed |
| **Automation** | Renovate for dependency PRs, Ansible Runner CronJobs for host-level tasks |

Roughly twenty applications run on top of it — media, documents, photos, notes, dashboards,
and a few self-hosted tools.

## How the filtering works

The interesting engineering problem in publishing a homelab repository is not secrets. Secrets
are solved: everything sensitive is SOPS-encrypted and always has been. The problem is
**topology** — a repository like this otherwise hands a reader a precise inventory of every
hostname, every LAN address and which admin interfaces exist where.

So the domain, the LAN prefixes and the tailnet name are not written literally anywhere in
these manifests. They live in an encrypted Secret and Flux substitutes them at reconcile time
through `postBuild.substituteFrom`:

```yaml
# infrastructure/coredns/coredns-custom.yaml
rewrite name docs.${DOMAIN} envoy-proxy.envoy-gateway-system.svc.cluster.local
```

```yaml
# apps/jellyfin/helm.yaml
kube-vip.io/loadbalancerIPs: "${LAN_PREFIX}.24"
```

Four variables cover the whole repository: `${DOMAIN}`, `${TAILNET}`, `${LAN_PREFIX}` and
`${MGMT_PREFIX}`. Last octets stay literal, because a bare `.24` reveals nothing without the
prefix — and it means adding a service never requires touching the encrypted Secret.

### The part that is easy to get wrong

Flux's substitution replaces a variable it cannot resolve with an **empty string**, and reports
success. A typo does not fail the reconcile; it deploys a working-looking resource with a hole
in it. Three separate landmines in this repository would have been silently detonated by
switching it on:

- an init script writing `${TELEGRAM_BOT_TOKEN}` into a bot's config, which would have produced
  a healthy pod authenticating with a blank token
- 236 `${1}`/`${2}`/`${3}` capture groups in a graphite exporter's metric mapping rules
- a single `$$hashKey`, an AngularJS artifact in exported Grafana dashboard JSON, which
  `envsubst` reads as an escape and collapses to `$hashKey`

`.github/workflows/validate.yaml` catches the first two class of problem in CI, by rendering
every path that has substitution enabled and running `flux envsubst --strict` over it. It
cannot catch the third — a `$$` that collapses is not an unresolved variable — so the rollout
was done one path at a time, each proved by diffing the rendered output before and after and
requiring it to be byte-identical.

## Layout

```
clusters/prod/      Flux entrypoint: which paths get reconciled, in what order
infrastructure/     Cluster components (ingress, DNS, storage, monitoring, operators)
apps/               Applications, mostly plain manifests, some Helm
  └── external/     Gateway routes to services running outside the cluster
```

`.claude/` and internal planning notes are not published.
