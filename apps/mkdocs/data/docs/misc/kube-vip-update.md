# Updating kube-vip

kube-vip is managed by **FluxCD** via a Kustomization that points to `infrastructure/kube-vip/`. Updates are fully automated through the GitOps workflow.

## Update flow

1. **Renovate** opens a PR with the new image tag in `infrastructure/kube-vip/kube-vip.yaml`
2. Review and **merge** the PR
3. Flux detects the change (via webhook or next reconciliation interval) and applies it automatically

To trigger reconciliation immediately after merging:

```bash
flux reconcile kustomization kube-vip
```

## Verification

Confirm the DaemonSet is running with the expected image:

```bash
kubectl -n kube-system get ds kube-vip-ds
kubectl -n kube-system get ds kube-vip-ds -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Check the Flux Kustomization status:

```bash
flux get kustomization kube-vip
```
