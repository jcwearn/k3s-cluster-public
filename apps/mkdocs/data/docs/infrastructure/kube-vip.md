<!-- docs/infrastructure/kube-vip.md -->
# kube-vip

`kube-vip` provides a **virtual IP (VIP)** and leader-election so the
control-plane API is always reachable on a single address. It is deployed as a
**DaemonSet** on control-plane nodes and managed by Flux via a Kustomization
pointing to `infrastructure/kube-vip/`.

| Purpose | How it's used here |
|---|---|
| HA control-plane | VIP `${LAN_PREFIX}.10` fronts the embedded etcd API servers on interface `enp0s18`. |
| LoadBalancer services | Any Service of `type: LoadBalancer` gets an IP from the ${LAN_PREFIX}.x range via kube-vip instead of MetalLB. |

## Configuration

Key environment variables on the DaemonSet:

| Variable | Value | Description |
|---|---|---|
| `address` | `${LAN_PREFIX}.10` | Virtual IP address |
| `vip_interface` | `enp0s18` | Network interface for ARP |
| `cp_enable` | `true` | Control-plane VIP mode |
| `svc_enable` | `true` | LoadBalancer service mode |
| `vip_leaderelection` | `true` | Use Kubernetes leases for leader election |

## Bootstrap vs Flux

During **initial cluster creation**, the kube-vip manifest is symlinked into
`/var/lib/rancher/k3s/server/manifests/` so it runs before the API server is
available (see [Bootstrapping k3s](../misc/bootstrapping-k3s.md)). Once Flux is
running, it takes over management of kube-vip from `infrastructure/kube-vip/`.

## Updates

Renovate creates PRs for image bumps. After merging, Flux reconciles the change
automatically. See [Updating kube-vip](../misc/kube-vip-update.md) for details.
