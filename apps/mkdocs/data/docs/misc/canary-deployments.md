# Canary Deployments

A second copy of one app, beside the real one, for the rare change that needs a rehearsal: a
major version bump with a migration, a chart upgrade with a values rewrite, an image that
changed its data layout. There is no staging cluster and there will not be one — the
[security page](security-hardening.md) explains why — so this is what rehearsal looks like here.

It is a pattern, not tooling. A canary is an ordinary overlay under `apps/`, which means Flux
deploys it, CI lints it, and deleting the directory removes it.

## The overlay

`apps/<app>-canary/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app>-canary
resources:
  - ../<app>
patches:
  - target:
      kind: HTTPRoute
    patch: |
      - op: replace
        path: /spec/hostnames/0
        value: canary-<host>.${DOMAIN}
  - target:
      kind: Deployment
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: <the image under test>
```

The `namespace:` transformer renames the base's `Namespace` object and moves every resource into
it, so the canary is fully separate from the real app: its own Deployment, Service, PVCs and
route. Nothing in the base changes.

Two more things every canary needs:

1. **A CoreDNS rewrite** for the new hostname in `infrastructure/coredns/coredns-custom.yaml`,
   like every other hostname, so it resolves from inside the cluster.
2. **Fresh data.** The overlay's PVC has the same *name* as the base's, but it is in a
   different namespace, so it is a new, empty volume. Never point a canary at the real app's
   PVC: two instances of most apps on one volume is corruption, and the canary's whole point is
   to be able to break things.

## Data for the canary

- **Stateless apps** (static sites, exporters): nothing to do.
- **Apps with a PVC**: start empty, or restore a copy. For an NFS volume that is a `cp` on
  TrueNAS from the real dataset's directory into the canary's, once the canary's PVC has been
  provisioned and its directory exists.
- **Apps on CloudNativePG**: the base's `Cluster` object is copied into the canary namespace
  too, and it will create an empty database. To rehearse a migration against real data, replace
  it with a recovery from the nightly backup — the pattern is in
  [Postgres backups](../infrastructure/postgres-backups.md) under the restore runbook, with
  the canary namespace as the target.

## Things that do not copy cleanly

- **LoadBalancer IPs.** A Service with a `kube-vip.io/loadbalancerIPs` annotation would claim
  the same address twice. Patch the annotation away in the overlay, or the Service type to
  `ClusterIP`; the HTTPRoute is how the canary is reached.
- **Tailscale exposure.** `tailscale.com/hostname` is a singleton on the tailnet. Patch it away.
- **Secrets.** SOPS-encrypted Secrets copy fine — Flux decrypts them for any namespace — but
  a canary using the real app's API tokens acts as the real app (sends the real notifications,
  writes to the real external service). Decide whether that is wanted.
- **Things the base reaches by fixed name**, like a `<svc>.<ns>.svc` URL in a ConfigMap, still
  point at the real namespace. Patch them or accept it.

## Running the rehearsal

Merge the overlay, wait for the canary to be Ready, exercise it at `canary-<host>.${DOMAIN}`,
read its logs. If the upgrade is a version bump, the real change is then the same image tag in
the base — one line — and the canary has already proven it.

## Removing it

Delete the directory and merge. `prune: true` on the apps Kustomization removes every object the
overlay created, including the PVC and its data, and the CoreDNS rewrite line goes in the same
commit. A canary that stays around becomes a second production instance nobody meant to have.
