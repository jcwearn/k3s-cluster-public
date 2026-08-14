# Updating Flux Version

Flux is managed by the **Flux Operator** via a `FluxInstance` CRD. Upgrades are performed by changing the distribution version in the FluxInstance spec and letting GitOps reconcile.

## Prerequisites

- Access to the cluster repository
- `kubectl` and `flux` CLI tools installed

## Upgrade Process

### 1. Check the Current Version

```bash
flux version
kubectl -n flux-system get fluxinstance flux -o jsonpath='{.spec.distribution.version}'
```

### 2. Update the FluxInstance Spec

Edit `infrastructure/flux-operator/fluxinstance.yaml` and set the desired version:

```yaml
spec:
  distribution:
    version: "2.x"  # or pin to e.g. "2.5.0"
```

Using `"2.x"` keeps you on the latest 2.x release automatically. To pin a specific version, replace it with the exact semver tag (e.g. `"2.5.0"`).

### 3. Commit and Create a PR

```bash
git checkout -b chore/flux-upgrade
git add infrastructure/flux-operator/fluxinstance.yaml
git commit -m "Upgrade Flux to vX.Y.Z"
git push origin chore/flux-upgrade
gh pr create --fill
```

### 4. Merge and Verify

After the PR merges, Flux reconciles the updated FluxInstance. Verify:

```bash
flux version
kubectl -n flux-system get fluxinstance flux
flux get kustomizations -A
```

All Kustomizations should show `Ready` status.

## Upgrading the Flux Operator Itself

The Flux Operator is deployed via HelmRelease in `infrastructure/flux-operator/helmrelease.yaml`. Renovate will open PRs for new operator chart versions automatically. After merging, verify:

```bash
kubectl -n flux-system get pods -l app.kubernetes.io/name=flux-operator
```

## Troubleshooting

### FluxInstance Not Reconciling

```bash
kubectl -n flux-system describe fluxinstance flux
kubectl -n flux-system logs -l app.kubernetes.io/name=flux-operator
```

### Flux Components Unhealthy After Upgrade

```bash
flux get sources git -A
flux get kustomizations -A
kubectl -n flux-system get pods
```

If a specific component is failing, check its logs:

```bash
kubectl -n flux-system logs -l app=source-controller
kubectl -n flux-system logs -l app=kustomize-controller
```

## Post-Upgrade Checklist

- All Flux pods running in `flux-system` namespace
- All Kustomizations showing `Ready` status
- All HelmReleases reconciling successfully
- Git repository source showing `Ready`
