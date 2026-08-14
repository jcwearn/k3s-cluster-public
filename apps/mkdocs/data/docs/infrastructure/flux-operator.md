# Flux Operator

*Manages the entire Flux installation, GitHub App authentication, and push-based webhook reconciliation — deployed with **Helm** and managed by **FluxCD**.*

The [Flux Operator](https://github.com/controlplaneio-fluxcd/flux-operator) replaces the traditional `flux bootstrap` workflow with a declarative `FluxInstance` CRD. Instead of Flux managing its own installation, the operator manages Flux — making upgrades, component selection, and configuration changes a simple YAML edit.

---

## Helm release at-a-glance

| Setting                | Value                                              |
| ---------------------- | -------------------------------------------------- |
| **Chart**              | `flux-operator`                                    |
| **Version**            | `0.41.1` (managed by Renovate)                     |
| **Repository**         | OCI — `oci://ghcr.io/controlplaneio-fluxcd/charts` |
| **HelmRelease**        | `flux-system/flux-operator`                        |
| **Reconcile interval** | Every 10 minutes                                   |
| **CRDs**               | Installed (`Create`) and replaced on upgrade (`CreateReplace`) |
| **Namespace**          | `flux-system`                                      |

<details>
<summary>HelmRelease source YAML</summary>

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  type: oci
  url: oci://ghcr.io/controlplaneio-fluxcd/charts
  interval: 10m
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 10m
  chart:
    spec:
      chart: flux-operator
      version: 0.41.1
      sourceRef:
        kind: HelmRepository
        name: flux-operator
        namespace: flux-system
  install:
    crds: Create
  upgrade:
    crds: CreateReplace
```

</details>

---

## FluxInstance

The `FluxInstance` CRD is the core declaration that tells the operator how to install and configure Flux. A single resource named `flux` in the `flux-system` namespace controls everything.

| Setting               | Value                                                        |
| --------------------- | ------------------------------------------------------------ |
| **Distribution**      | `2.7.5` from `ghcr.io/fluxcd`                               |
| **Components**        | source-controller, kustomize-controller, helm-controller, notification-controller |
| **Cluster type**      | `kubernetes` (single-tenant, NetworkPolicy enabled)          |
| **Sync source**       | `GitRepository` — `https://github.com/jcwearn/k3s-cluster.git` (branch `main`) |
| **Sync path**         | `clusters/prod`                                              |
| **Auth provider**     | `github` (GitHub App tokens)                                 |

### Performance patches

The FluxInstance applies JSON patches to the kustomize-controller and helm-controller deployments:

| Flag                     | Effect                                                    |
| ------------------------ | --------------------------------------------------------- |
| `--concurrent=10`        | Process up to 10 reconciliations in parallel (default: 4) |
| `--requeue-dependency=5s` | Re-check dependency readiness every 5 seconds (default: 30s) |

These patches significantly speed up reconciliation after a push, especially when many Kustomizations and HelmReleases depend on each other.

<details>
<summary>FluxInstance source YAML</summary>

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.7.5"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    type: kubernetes
    multitenant: false
    networkPolicy: true
    domain: "cluster.local"
  kustomize:
    patches:
      - patch: |
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --concurrent=10
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --requeue-dependency=5s
        target:
          kind: Deployment
          name: "(kustomize-controller|helm-controller)"
  sync:
    kind: GitRepository
    provider: github
    url: "https://github.com/jcwearn/k3s-cluster.git"
    ref: "refs/heads/main"
    path: "clusters/prod"
    pullSecret: "flux-system"
```

</details>

---

## GitHub App authentication

Flux authenticates to GitHub using a **GitHub App** rather than personal access tokens or SSH deploy keys. This eliminates token expiry — Flux generates short-lived installation tokens automatically.

### How it works

1. A GitHub App named `flux-k3s-cluster` is installed on the `jcwearn/k3s-cluster` repository.
2. The app has **Contents (read & write)** and **Metadata (read-only)** permissions.
3. The `provider: github` field in the FluxInstance sync configuration tells source-controller to use GitHub App tokens.
4. The `pullSecret: "flux-system"` references an **imperative** Secret (not stored in Git) containing:
   - `githubAppID`
   - `githubAppInstallationID`
   - `githubAppPrivateKey`
5. On each reconciliation, source-controller uses the private key to generate a short-lived installation token from the GitHub API, then uses that token to pull the repository.

> **See also:** [Rotating the GitHub App private key](../misc/rotating-flux-github-pat.md)

---

## Webhook receiver

A Flux `Receiver` resource enables push-based reconciliation. Instead of waiting up to 10 minutes for the next poll, GitHub notifies the cluster immediately after a push.

| Setting            | Value                                       |
| ------------------ | ------------------------------------------- |
| **Name**           | `github-push`                               |
| **Type**           | `github`                                    |
| **Events**         | `ping`, `push`                              |
| **Secret**         | `flux-webhook-token` (SOPS-encrypted in Git) |
| **Target resource** | `GitRepository/flux-system`                |

When a webhook arrives, the notification-controller:

1. Validates the `X-Hub-Signature-256` header using the HMAC token from the `flux-webhook-token` Secret.
2. If valid, annotates the `flux-system` GitRepository to trigger an immediate sync.
3. Source-controller detects the annotation, pulls the latest commit, and kicks off reconciliation.

---

## Webhook ingress (Tailscale Funnel)

The webhook endpoint is exposed publicly using **Tailscale Funnel** — not Envoy Gateway. This avoids opening a public port on the cluster's ingress IP.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flux-webhook
  namespace: flux-system
  annotations:
    tailscale.com/funnel: "true"
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: webhook-receiver
      port:
        number: 80
  tls:
    - hosts:
        - flux-webhook
```

| Detail                  | Value                                                    |
| ----------------------- | -------------------------------------------------------- |
| **Ingress class**       | `tailscale` (Tailscale Operator provisions the endpoint) |
| **Public URL**          | `https://flux-webhook.<tailnet>.ts.net`                  |
| **TLS**                 | Managed automatically by Tailscale                       |
| **Funnel annotation**   | `tailscale.com/funnel: "true"` — exposes to the public internet via Tailscale's edge network |

### Configuring the webhook in GitHub

1. Navigate to **Repository → Settings → Webhooks → Add webhook**.
2. **Payload URL:** `https://flux-webhook.<tailnet>.ts.net/hook/<receiver-hash>`
   (get the hash with `kubectl -n flux-system get receiver github-push -o jsonpath='{.status.webhookPath}'`)
3. **Content type:** `application/json`
4. **Secret:** the plaintext HMAC token from `flux-webhook-token`
5. **Events:** select "Just the push event" (ping is sent automatically on creation).

---

## End-to-end reconciliation flow

1. A developer pushes a commit to the `main` branch.
2. GitHub sends a `push` webhook to the Tailscale Funnel URL.
3. The notification-controller validates the HMAC signature and annotates `GitRepository/flux-system`.
4. Source-controller detects the annotation, generates a fresh GitHub App installation token, and pulls the repository.
5. Source-controller produces a new artifact (tarball of `clusters/prod`).
6. Kustomize-controller picks up the new artifact and reconciles all Kustomization resources (infrastructure, then apps).
7. Helm-controller reconciles any HelmReleases referenced by those Kustomizations.
8. The cluster state matches the latest Git commit — typically within seconds of the push.

---

## Secret management

Two secrets are involved in the Flux Operator setup:

| Secret               | Namespace     | Storage                   | Contents                                                   |
| -------------------- | ------------- | ------------------------- | ---------------------------------------------------------- |
| `flux-webhook-token` | `flux-system` | SOPS-encrypted in Git     | HMAC token for webhook signature validation                |
| `flux-system`        | `flux-system` | Imperative (not in Git)   | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` |

The `flux-webhook-token` secret is managed declaratively — edit it with `sops infrastructure/flux-operator/secrets.sops.yaml`. The `flux-system` secret is created imperatively because it contains the GitHub App private key; see [Rotating the GitHub App private key](../misc/rotating-flux-github-pat.md) for update instructions.

---

## Further reading

* **Flux Operator docs:** [https://github.com/controlplaneio-fluxcd/flux-operator](https://github.com/controlplaneio-fluxcd/flux-operator)
* **Flux GitHub App auth:** [https://fluxcd.io/flux/components/source/gitrepositories/#github](https://fluxcd.io/flux/components/source/gitrepositories/#github)
* **Flux Receiver docs:** [https://fluxcd.io/flux/components/notification/receivers/](https://fluxcd.io/flux/components/notification/receivers/)
* **Tailscale Funnel:** [https://tailscale.com/kb/1223/funnel](https://tailscale.com/kb/1223/funnel)
