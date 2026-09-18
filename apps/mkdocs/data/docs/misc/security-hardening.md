# Security Hardening

Where this cluster actually stands on each security layer, what is being done about the gaps, and
what is deliberately being left alone. This page is the honest inventory; the phased work that
closes the gaps is tracked in `docs/plans/cluster-hardening/` in the repository.

## Threat model

One admin, one cluster, and everything on it is production. Ingress is tailnet-only: every
HTTPRoute's hostname is a CNAME to `k3s-gateway.${TAILNET}`, so nothing answers on the public
internet except the Flux webhook receiver, which is funneled on purpose. That narrows the realistic
threats to four, in the order they are most likely to bite:

| Risk | Why it is real here |
| --- | --- |
| **A bad merge** | There is no staging environment. A broken manifest, a chart upgrade with a migration, or a `$$$$` that collapses in substitution lands on the real thing within ten minutes. |
| **Lateral movement from a compromised container** | Most pods run as root, mount a `default` ServiceAccount token they never use, and can reach every other pod on the cluster. An RCE in any one web app is a foothold on all of them. |
| **Supply chain** | Renovate pins nearly every image by digest and automerges patches, which is the right posture — but a handful of images are still tag-only or untagged, and nothing scans what is running. |
| **Data loss** | Postgres is backed up off-site to R2 and the restore is proven. etcd is not: k3s's default snapshots sit on the same local disk as the node. Lose the three VMs and the cluster's state goes with them. |

Container escape and hypervisor compromise are lower on the list — the hosts are on a management
LAN, not the internet, and the k3s guests are the only tenants.

## Where each layer stands

Facts, as of the date at the bottom of the page. Each row links to the phase that changes it.

### Control plane and nodes

| Item | State |
| --- | --- |
| k3s version | `v1.36.4+k3s1`, pinned in [system-upgrade-controller](../infrastructure/system-upgrade-controller.md); Renovate proposes patches, minors go by hand |
| `anonymous-auth`, authorization mode | k3s defaults: anonymous auth off, `Node,RBAC`. **Nothing to do** — the old checklist item here was wrong for k3s |
| Server configuration | No `/etc/rancher/k3s/config.yaml` on any node; every argument is in the systemd unit's `ExecStart` |
| API audit log | **None** → phase 9 |
| Secrets encryption at rest | **Off** — Secrets are plaintext in etcd → phase 9 |
| `protect-kernel-defaults` | **Off** → phase 9 |
| etcd snapshots | k3s default: local disk only, no off-site copy → phase 9 |
| Pod Security Admission | **Not enforced.** Two namespaces carry `enforce: privileged` (csi-driver-nfs, system-upgrade) so that turning enforcement on later does not break them; the other 34 are unlabelled → phase 7 |
| Admission configuration | None; a namespace created outside Git gets no policy at all → phase 9 |

### Workloads

| Item | State |
| --- | --- |
| `securityContext` | 5 of 40 raw workloads are fully hardened (`hivemind` is the template: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`). 4 set a UID or `fsGroup` and nothing else. The rest set nothing and run as whatever the image says, which is usually root → phase 6 |
| ServiceAccounts | ~25 pods run on `default` with the token auto-mounted. Nobody sets `automountServiceAccountToken: false`. Dedicated SAs exist only where the API is actually used (homepage, ansible, withjoy-exporter, kube-vip, system-upgrade) → phase 6 |
| `cluster-admin` | One binding, to `headlamp-admin`, a ServiceAccount with no stored token: write sessions in Headlamp use a token minted for a few hours. Headlamp's own account holds `view` |
| Root-requiring images | adguardhome (binds :53), linuxserver s6 images (calibre-web, shelfmark, paperless-ngx), the ansible CronJobs (`runAsUser: 0`), gluetun (`NET_ADMIN` + `/dev/net/tun`), kube-vip (`hostNetwork`), csi-driver-nfs, system-upgrade Jobs. These are the permanent exception list |
| Health probes | Every raw workload has liveness and readiness (startup too where boot is slow), and `kube-linter` refuses a new one without them. Excepted with a reason: kube-vip (restarting the VIP holder is worse than a hang), the system-upgrade-controller (nothing to probe), and every CronJob |
| Image pinning | Tag + digest everywhere CI can see, enforced by `scripts/check-image-digests.sh`. Two deliberate exceptions in `.ci/image-pin-allowlist`: the k3s upgrade image, whose tag the Plan derives at run time, and the vendored system-upgrade-controller manifest |

### Network

| Item | State |
| --- | --- |
| CNI | Flannel, k3s default. **k3s's embedded network-policy controller is active**, so `NetworkPolicy` objects are enforced without a CNI change — another place the old checklist was wrong |
| NetworkPolicy | **None**, apart from the Flux operator's own (`cluster.networkPolicy: true`). Every pod can reach every other pod and every Postgres instance → phase 8 |
| Ingress | Envoy Gateway on one LoadBalancer IP, wildcard certificate from cert-manager, hostnames resolve to the Tailscale gateway. `insecureSkipVerify` only towards the external HTTPS backends (Proxmox, TrueNAS, UniFi), which present self-signed certificates |
| Public exposure | The Flux webhook receiver, via Tailscale Funnel, authenticated by a shared secret. Nothing else |

### Secrets and supply chain

| Item | State |
| --- | --- |
| Secrets in Git | SOPS + age, decrypted by Flux. The one age key is the root of trust; `scripts/check-sops-files.sh` catches the copied-not-encrypted mistake in CI. **This is the right size for the cluster** — External Secrets or Vault would add a running secret store whose job is to protect a single key that already lives in one place |
| Public mirror | The repo is mirrored publicly with the domain, LAN prefixes and tailnet name substituted at reconcile time; gitleaks runs on the rendered tree before every push |
| Dependency updates | Renovate CronJob with OSV vulnerability alerts, digest pinning, non-major automerge |
| CI | Every overlay rendered as Flux applies it, then `kubeconform -strict` with the CRD schemas, `kube-linter` with the repo's rules, an image-digest check, yamllint, zizmor, and a rendered diff on every pull request. A weekly Trivy scan keeps a GitHub issue current. The same checks run as git hooks before a commit exists |
| Flux alerting | Every failed Kustomization or GitRepository reconcile is posted to Alertmanager and reaches ntfy through the catch-all route. The [fast-revert runbook](fast-revert.md) is what to do next |

## The roadmap

Ordered so that nothing which can take a pod down lands before the alerting that would report it.

| Phase | What changes | Prod risk |
| --- | --- | --- |
| 1 | ~~This page; the plan and progress tracker~~ done | none |
| 2 | ~~CI: schema validation (kubeconform), linting (kube-linter, yamllint), digest-pin check, rendered diff on every PR, weekly image scan~~ done | none |
| 3 | ~~Git hooks: the same checks before a commit, plus a guard against committing a plaintext Secret or a literal address~~ done | none |
| 4 | ~~Liveness and readiness probes on every workload~~ done | low |
| 5 | ~~Flux → Alertmanager → ntfy on any failed reconcile; a [fast-revert runbook](fast-revert.md); a [canary-namespace pattern](canary-deployments.md) for risky upgrades~~ done | none |
| 6 | `securityContext` on every raw workload, `automountServiceAccountToken: false` by default, image digests everywhere, Headlamp off `cluster-admin` | low–medium, per app |
| 7 | Pod Security Admission: `warn`/`audit` everywhere, then `enforce: baseline`, then `restricted` one namespace at a time | low |
| 8 | NetworkPolicy, targeted: Postgres ingress, egress limits on the LLM workloads, ingress limits on the secret-bearing apps | medium, per namespace |
| 9 | Node configuration via Ansible: etcd snapshots to R2, audit log, secrets encryption, `protect-kernel-defaults`, a cluster-wide PSA default | high — k3s restarts |
| 10 | Optional: `flux diff` against the live cluster from CI | none to the cluster |

## Why there is no staging environment

The natural answer to "a bad merge breaks prod" is a second environment, and it was considered
seriously. It does not fit this hardware. Each k3s guest is allocated its host's entire CPU and
RAM, so a staging cluster means shrinking the production guests; ~25 Services pin LoadBalancer
addresses on the one LAN, external-dns owns one zone under one `txtOwnerId`, and the Tailscale
hostnames are singletons — every one of those is a collision to design around. A vcluster shares
the nodes but cannot exercise kube-vip, the NFS driver, Tailscale or a k3s upgrade, which are the
changes most likely to hurt.

The trade made instead: make a bad merge **visible before it merges** (rendered diffs, schema and
policy checks in CI), **loud when it lands** (Flux alerts), and **cheap to undo** (the revert
runbook). For the rare change that genuinely needs a rehearsal, the
[canary-namespace pattern](canary-deployments.md) runs a second copy of one app beside the real one.

## Deliberate non-goals

| Not doing | Because |
| --- | --- |
| Kyverno / Gatekeeper | Pod Security Admission covers the runtime policy that matters here, and kube-linter in CI covers the repo conventions (resources, probes, no `latest`) before they reach the cluster. A policy engine would be a third place to encode the same rules |
| cosign image verification | Almost every image is pinned by digest through Renovate; the digest *is* the integrity check. Signature verification would add an admission webhook for images this cluster does not build |
| Falco / Tetragon | Runtime syscall detection on a one-admin cluster with nobody to triage the stream. The audit log (phase 9) answers the forensic question this would |
| kube-bench as a CronJob | Run it once by hand after phase 9 and record the result; a weekly report nobody reads is noise |
| External Secrets / Vault | See above — SOPS is the right size |
| Cloudflare Tunnel in front of everything | Already tailnet-only; there is nothing public to put a tunnel in front of |

## Conventions that keep the posture from drifting

- Every container declares `resources` with requests and limits. CI enforces it.
- Every new raw workload copies the `hivemind` `securityContext` and probe block, then removes only
  what the image genuinely cannot tolerate — with a comment saying why.
- A pod that does not talk to the API server sets `automountServiceAccountToken: false`.
- A permanent exception to a lint check or a PSA level carries an
  `ignore-check.kube-linter.io/<check>` annotation with the reason. That annotation list is the
  exception list; there is no second one.
- New permissions are proven, not guessed: observe the failure, then permit the exact verb,
  resource or port. Under GitOps that is one more PR and a paper trail.

*Inventory taken 2026-09-18.*
