# Descheduler

[Descheduler](https://github.com/kubernetes-sigs/descheduler) evicts pods from over-loaded nodes so the Kubernetes scheduler can redistribute them to under-utilized nodes.

* **Install:** Flux HelmRelease `descheduler` (`v0.32.0`)
* **Mode:** CronJob — runs hourly (`0 * * * *`) for controlled eviction bursts (no continuous oscillation)

## Why it's needed

After a rolling node restart, k3s-01 ended up with 54 pods while k3s-03 had 2. Kubernetes doesn't rebalance pods automatically after node restarts. The descheduler detects this imbalance and evicts pods from over-utilized nodes so the scheduler can place them on under-utilized ones.

## Policy: LowNodeUtilization

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `thresholds.cpu/memory/pods` | 20% | Nodes below 20% on all three dimensions are candidates to receive evicted pods |
| `targetThresholds.pods` | 40% | Nodes above 40% pod capacity (44 pods on 110-pod nodes) are candidates for eviction — pod count is the sole eviction trigger since homelab workloads are mostly idle |
| `maxNoOfPodsToEvictPerNode` | 5 | Rate-limits evictions per hourly run |
| `maxNoOfPodsToEvictPerNamespace` | 3 | Prevents draining a single namespace |

### Excluded namespaces

`kube-system`, `kube-public`, `kube-node-lease`, `flux-system`, `cnpg-system`, `envoy-gateway-system`, `tailscale`, `prometheus`, `descheduler`

Exclusions are set via `evictableNamespaces` on the `LowNodeUtilization` plugin args.

## Safety guardrails

| Setting | Value | Effect |
|---------|-------|--------|
| `ignorePvcPods` | `true` | Never evicts pods with PVCs (protects CNPG, Immich, Paperless, Jellyfin) |
| `nodeFit` | `true` | Only evicts a pod if another node can actually receive it |
| `evictSystemCriticalPods` | `false` | System-critical pods are never evicted |
| `priorityThreshold.value` | 2000000000 | Protects very high-priority pods |

CNPG also auto-creates PodDisruptionBudgets which the descheduler respects by default.
