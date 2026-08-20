# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a GitOps-managed Kubernetes homelab running on a 3-node k3s cluster. FluxCD continuously reconciles Git manifests to cluster state. All configuration is declarative - changes are made by editing YAML files and pushing to Git.

The k3s nodes are **virtual machines**, one per Proxmox VE host (`k3s-01/02/03` on `pve-01/02/03`, VMIDs 100/201/301). Storage is local LVM-thin with no shared storage, so hypervisor work means draining the node and shutting the VM down rather than migrating it. The hardware is three Beelink SER8s; they are the hypervisors, not the k3s nodes.

## Repository Structure

```
clusters/prod/           # Flux entrypoint - defines what gets deployed
  ├── flux-system/       # FluxCD bootstrap components
  ├── infrastructure.yaml # Infrastructure Kustomization definitions
  └── apps.yaml          # Apps Kustomization (depends on all infrastructure)

infrastructure/          # Cluster infrastructure components
  ├── cert-manager/      # TLS certificate automation (Let's Encrypt + Cloudflare)
  ├── cloudnative-pg/    # PostgreSQL operator
  ├── coredns/           # DNS server configuration
  ├── descheduler/       # Pod eviction for even node utilization
  ├── envoy-gateway/     # Gateway API ingress (Envoy proxy)
  ├── external-dns/      # DNS record sync to Cloudflare
  ├── flux-operator/     # Flux Operator + FluxInstance + webhook receiver
  ├── kube-vip/          # HA virtual IP for control plane + LoadBalancer
  ├── llama-cpp/         # Local LLM inference server (Qwen3, CPU)
  ├── prometheus/        # Monitoring stack (kube-prometheus-stack + TrueNAS/Proxmox monitoring)
  ├── reloader/          # Auto-restart on ConfigMap/Secret changes
  ├── tailscale-operator/ # Private VPN network overlay
  └── truenas-nfs/       # NFS storage provisioner

apps/                    # User-facing applications
  ├── adguardhome/       # DNS resolver & ad blocker
  ├── ansible/           # Ansible Runner CronJobs (infra automation)
  ├── coder/             # Cloud development environments (code.${DOMAIN})
  ├── ebooks/            # E-book library (Calibre-Web + Calibre)
  ├── headlamp/          # Kubernetes dashboard
  ├── hivemind/          # Party game (one snake, everybody steers)
  ├── homepage/          # Dashboard
  ├── immich/            # Photo management
  ├── it-tools/          # Developer utilities
  ├── jellyfin/          # Media server
  ├── mazanoke/          # Image compression
  ├── mkdocs/            # Documentation site
  ├── n8n/               # Workflow automation
  ├── ntfy/              # Push notifications
  ├── paperless-ngx/     # Document management
  ├── open-webui/        # Chat UI for LLMs
  ├── renovate/          # Dependency update bot (CronJob)
  ├── stirling-pdf/      # PDF tools
  ├── uptime-kuma/       # Uptime monitoring
  ├── withjoy-exporter/  # WithJoy guest list → Google Sheets (CronJob + web trigger)
  ├── zeroclaw/          # AI personal assistant (Telegram + Gemini)
  └── external/          # Ingress for non-K8s services
      ├── homeassistant/ # Home automation
      ├── proxmox/       # Hypervisor UI
      ├── truenas/       # NAS management UI
      └── unifi/         # Network controller

```

## Key Technologies

- **k3s**: Lightweight Kubernetes on 3-node HA cluster
- **FluxCD**: GitOps reconciliation (10-minute intervals)
- **SOPS + age**: Secret encryption (files ending in `.sops.yaml`)
- **kube-vip**: Floating VIP for HA control plane + LoadBalancer IPs
- **Helm**: Most components deployed via HelmRelease resources

## Deployment Patterns

### Infrastructure (Helm-based)
Components in `infrastructure/` typically include:
- `namespace.yaml` - Namespace definition
- `helmrepository.yaml` - Helm chart source
- `helmrelease.yaml` - HelmRelease with values
- `kustomization.yaml` - Lists resources to include
- `secrets.sops.yaml` - Encrypted secrets (when needed)

Every HelmRelease **must** include a `resources:` block in its values. The correct key path varies by chart (check `helm show values`) — common patterns are top-level `resources:`, `controller.resources:`, or `operatorConfig.resources:`.

### Applications (Kustomize-based)
Apps in `apps/` typically include standard K8s manifests:
- `namespace.yaml`, `deployment.yaml` or `statefulset.yaml`
- `service.yaml`, `httproute.yaml`, `pvc.yaml`
- `configmap.yaml`, `secret.yaml` or `secrets.sops.yaml`

Every container and initContainer in a Deployment/StatefulSet/CronJob **must** include a `resources:` block with both `requests` and `limits`.

### Applications (Helm-based)
Some apps (immich, coder, open-webui) use Helm instead of raw manifests. These combine HelmRepository + HelmRelease into a single `helm.yaml` file alongside `namespace.yaml` and `kustomization.yaml`.

Every `helm.yaml` HelmRelease **must** include a `resources:` block in its values (same rules as infrastructure above).

### External Services
Apps in `apps/external/` proxy traffic to services running outside the cluster:
- **HTTP backends** (e.g., homeassistant): `service.yaml` (headless Service + EndpointSlice) + `httproute.yaml`
- **HTTPS backends** (e.g., proxmox, truenas, unifi): `backend.yaml` (Backend CRD with `insecureSkipVerify` + `alpnProtocols: ["http/1.1"]`) + `httproute.yaml` + `backend-traffic-policy.yaml`
- `namespace.yaml` - Namespace for the service
- `kustomization.yaml` - Lists resources to include

Current external services: homeassistant, proxmox, truenas, unifi.

## Reconciliation Order

Defined in `clusters/prod/infrastructure.yaml` and `clusters/prod/apps.yaml`:

1. cert-manager → cert-manager-issuer
2. external-dns, envoy-gateway → envoy-gateway-config, kube-vip, prometheus, reloader, truenas-nfs, cloudnative-pg, coredns, llama-cpp, flux-operator
3. tailscale-operator → tailscale-connector
4. **apps** (depends on: cert-manager-issuer, external-dns, envoy-gateway-config, prometheus, tailscale-connector, truenas-nfs, cloudnative-pg, llama-cpp)

## Working with Secrets

Secrets are encrypted with SOPS using age keys. Flux decrypts them automatically during reconciliation.

Age public key: `age1ssrlddcqe0jrh2g3038538wuk6uzegz49gyvak2elm7rh2ccj3pq8vnz7t`

To edit an encrypted secret:
```bash
sops apps/some-app/secrets.sops.yaml
```

To create a new encrypted secret, write the plaintext Secret to a file ending in
`.sops.yaml` and encrypt it in place:
```bash
sops -e -i apps/some-app/secrets.sops.yaml
```

`.sops.yaml` at the repo root supplies the recipient and the `encrypted_regex`,
so no flags are needed. That file exists because its absence caused a real bug:
with every encrypt requiring a hand-typed 59-character recipient, someone copied
an existing encrypted file and edited the namespace instead. The ciphertext was
valid, the MAC was not, and since Flux does not enforce the MAC the way the sops
CLI does, it went unnoticed for sixteen months — the cluster worked fine and the
file simply could not be opened.

**Never create an encrypted file by copying another one.** The MAC covers the
plaintext fields too, so a copy with an edited namespace produces a file that
Flux accepts and `sops` rejects. `scripts/check-sops-files.sh` fails CI on two
files sharing a MAC.

To verify every encrypted file locally (needs the age key, so it cannot run in
CI):
```bash
for f in $(git ls-files '*.sops.yaml'); do sops -d "$f" >/dev/null || echo "BAD: $f"; done
```

## Common Tasks (Skills)

Claude Code skills are available for common cluster operations. Use them by typing the command in the chat.

### Scaffolding & Editing
- `/add-app <name>` - Scaffold a new application (namespace, deployment, service, HTTPRoute, PVC, kustomization)
- `/add-external-service <name>` - Scaffold an external service proxy (HTTPRoute + Backend CRD for HTTPS backends)
- `/add-infra <name>` - Scaffold a Helm-based infrastructure component (HelmRepository + HelmRelease)
- `/edit <name> [description]` - Edit an existing app, infrastructure component, or external service
- `/encrypt-secret [path]` - Create or edit SOPS-encrypted secrets

### Operations (requires cluster access)
- `/status` - Cluster health overview (nodes, Flux, pods, certs, PVCs, resource usage)
- `/reconcile-flux [name]` - Force Flux reconciliation
- `/troubleshoot <resource-type> <namespace> [name]` - Diagnose cluster issues (pods, Flux, Helm, services, PVCs, certs, HTTPRoutes)
- `/verify-deployment <pr-number | app-name>` - Verify a change is deployed through the GitOps pipeline

### Validating changes locally

```bash
# Validate Kustomize output
kustomize build apps/homepage

# Check Flux reconciliation status
flux get kustomizations
flux get helmreleases -A
```

## Network Configuration

- **Domain**: `${DOMAIN}` (Cloudflare DNS)
- **Ingress**: Envoy Gateway (Gateway API) — all HTTPRoutes attach to `main-gateway` in `envoy-gateway-system`
- **LoadBalancer IPs**: `${LAN_PREFIX}.x` range via kube-vip annotations (Envoy proxy: `${LAN_PREFIX}.5`)
- **Tailscale exposure**: Add `tailscale.com/expose: "true"` annotation to services
- **Default TLS**: Wildcard cert at `envoy-gateway-system/wildcard-tls` — configured on the Gateway, not on individual routes
- **DNS**: Gateway annotation provides CNAME target (`k3s-gateway.${TAILNET}`) for all HTTPRoutes via external-dns
- **Apex domain**: `${DOMAIN}` uses a `DNSEndpoint` CRD with an A record (Cloudflare CNAME flattening doesn't work with external-dns ownership TXT records)
- **Split-horizon DNS**: Every `*.${DOMAIN}` HTTPRoute hostname must have a corresponding `rewrite name` entry in `infrastructure/coredns/coredns-custom.yaml` so in-cluster pods resolve to the Envoy proxy internally

## Variable Substitution

This repo is mirrored publicly, so the domain, the LAN prefixes and the tailnet name are not
written literally in any manifest. They live in a SOPS-encrypted Secret (`cluster-vars` in
`flux-system`, defined in `infrastructure/cluster-vars/`) and Flux resolves them at reconcile
time via `postBuild.substituteFrom`.

| Variable | Meaning |
| --- | --- |
| `${DOMAIN}` | Apex domain |
| `${TAILNET}` | Tailnet name |
| `${LAN_PREFIX}` | First three octets of the cluster LAN — use as `${LAN_PREFIX}.26` |
| `${MGMT_PREFIX}` | First three octets of the management LAN |
| `${R2_ENDPOINT}` | Cloudflare R2 S3 endpoint (embeds the account ID) |

Rules when editing:

- **Never write the domain, a `${LAN_PREFIX}.x` address, the tailnet or the Cloudflare account ID
  literally.** Use the variable. `.github/workflows/validate.yaml` cannot catch a literal — only a human review can.
- **Substitution only reaches the kustomize build output.** It applies to manifests and to
  anything pulled in by a `configMapGenerator` — all `apps/*/data/` except `apps/coder/data/`,
  plus `infrastructure/prometheus/data/`. It does not reach `.github/`, `.claude/`,
  `README.md`, `CLAUDE.md` or `docs/`.
- **A braced `${...}` that is not one of the five above will be replaced with an empty string,
  silently.** If a file needs a literal `${FOO}` — a shell variable in a doc, a regex capture
  group in an exporter config — escape it as `$${FOO}`. A literal `$$` must be written `$$$$`.
  Bare `$FOO` is left alone and needs no escaping.
- **Paths with substitution enabled are listed in `clusters/prod/`.** Adding `postBuild` to a
  new path means auditing that path for braced references first.

Before merging a change to a substituted path, confirm the render is unchanged:

```bash
kustomize build <path> | flux envsubst --strict
```

`--strict` fails on a variable that would blank, but it cannot see a `$$` that would collapse.
Diffing the rendered output against the previous commit's is the check that catches everything.

**Commit messages are published too.** `.github/workflows/publish.yaml` replays them onto the
public mirror verbatim, so do not name hostnames, addresses or the tailnet in a commit message —
there is no substitution step for those. `.claude/` and `docs/plans/` are excluded from the
mirror by `.publicignore` and may reference real values freely.

## Storage

Default storage class is `truenas-nfs-rwx` backed by TrueNAS NFS server (`${LAN_PREFIX}.200`).

## MkDocs Documentation

When adding a new app, infrastructure component, or external service, add a corresponding documentation page:

1. **Create the markdown file** at `apps/mkdocs/data/docs/<section>/<name>.md` (section is `apps`, `infrastructure`, or `misc`)
2. **Add it to the configMapGenerator** in `apps/mkdocs/kustomization.yaml` under the matching ConfigMap (`mkdocs-apps`, `mkdocs-infra`, or `mkdocs-misc`)
3. **Add a row to the section's index** at `apps/mkdocs/data/docs/<section>/index.md`
4. **Add a nav entry** in `apps/mkdocs/data/mkdocs.yml`

If adding an entirely new section, also create a new ConfigMap in the configMapGenerator and mount it in `apps/mkdocs/deployment.yaml`.

## Keeping Listings in Sync

When adding a new app, infrastructure component, or external service, update the directory tree listings in **all three files** so they stay consistent:

1. **`README.md`** — the `Repository Structure` tree
2. **`CLAUDE.md`** — the `Repository Structure` tree
3. **`apps/mkdocs/data/docs/index.md`** — the `Repository layout` tree and the relevant table (Workloads or Core add-ons)

Insert entries alphabetically, matching the format already used in each file. The `/add-app`, `/add-infra`, and `/add-external-service` skills include this as a post-creation step.

## Renovate

Automated dependency updates via Renovate CronJob. Configuration in `renovate.json`. Creates PRs for Helm chart and container image updates, grouped by directory (apps, infrastructure, flux-system).
