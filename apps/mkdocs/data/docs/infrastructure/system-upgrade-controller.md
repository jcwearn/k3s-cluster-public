# System Upgrade Controller

Upgrades k3s on the nodes themselves, declaratively, from a `Plan` in Git.

The gap this closes is specific. Renovate covers container images and Helm charts;
`ansible-update-linux` covers OS packages weekly. k3s is installed on the hosts by a shell script
and is neither, so its version existed only at runtime — which is how the cluster spent nearly six
months on a release that had reached upstream end of life without anything noticing. The
[EOL monitoring](eol-monitoring.md) alert found it; this is what fixes it, and what keeps the
version visible afterwards.

## How it works

```
Plan (Git)  --> controller  --> hash the spec into .status.latestHash
                                          |
                                          v
                        for each node whose label != hash, one at a time:
                                          |
                    cordon/drain --> Job on that node --> swap /usr/local/bin/k3s
                                          |                  --> restart k3s
                                          v
                          label the node with the hash, uncordon
                                          |
                                  postCompleteDelay
                                          |
                                          v
                                     next node
```

The controller stamps `plan.upgrade.cattle.io/<plan-name>=<hash>` on each node it finishes. A node
whose label disagrees with the current `.status.latestHash` is a node that needs work, which is what
makes a version bump in Git the entire trigger — there is no imperative step.

All three nodes here are `control-plane`, so this is **one Plan**, not the server/agent pair the
upstream documentation shows. The agent plan's `prepare` step exists to make workers wait for
servers, and there are no workers.

## Layout

| File | What it is |
|------|-----------|
| `crd.yaml` | The `Plan` CRD, vendored verbatim from the upstream release |
| `controller.yaml` | Namespace, ServiceAccount, RBAC, ConfigMap and Deployment, vendored verbatim |
| `patch-controller-resources.yaml` | Adds the `resources:` block the upstream Deployment omits |
| `patch-controller-env.yaml` | Overrides two ConfigMap defaults — see below |
| `plan-k3s.yaml` | The Plan. **The only file that changes per upgrade** |

Upstream publishes no Helm chart, only third-party ones, so the manifests are vendored the same way
[kube-vip](kube-vip.md) is. Re-vendoring is a clean overwrite:

```bash
V=v0.20.1
curl -sfL https://github.com/rancher/system-upgrade-controller/releases/download/$V/crd.yaml \
  -o infrastructure/system-upgrade-controller/crd.yaml
curl -sfL https://github.com/rancher/system-upgrade-controller/releases/download/$V/system-upgrade-controller.yaml \
  -o infrastructure/system-upgrade-controller/controller.yaml
```

## The settings that matter

Three of these are not in any upstream example, and each one is load-bearing on a three-node
embedded-etcd cluster.

| Setting | Why |
|---------|-----|
| `version:`, never `channel:` | `channel: .../stable` resolves to the newest k3s release, which right now is four minors ahead. k3s states plainly that the controller *"will not protect against unsupported changes to the Kubernetes version."* Upstream permits no minor skipping, so each hop is its own PR. |
| `concurrency: 1` | Quorum on three etcd members survives exactly one node down. |
| `postCompleteDelay` | The controller's only gate between nodes is "Job complete → label → next node," and a node can report `Ready` before its etcd member has caught up. This is the settle time, and without it `concurrency: 1` is not actually enough. |
| `SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE` | Ships pinned at `rancher/kubectl:v1.30.3`, and **that is the kubectl that performs the drain**. kubectl is supported within one minor of the apiserver. It has to move with the Plan version — treat the two as a single edit. |
| `SYSTEM_UPGRADE_JOB_ACTIVE_DEADLINE_SECONDS` | Ships at 900s. A Job here drains a node, pulls an image, swaps a binary and restarts k3s; 15 minutes is tight enough to trip on a slow-but-healthy run. Raised to an hour. |

## Running an upgrade

The full procedure — preconditions, per-hop pre-checks, what to watch, abort criteria — is in
`docs/plans/k3s-eol-upgrade/plan.md`, which is not published here because it names real addresses.
The short version:

```bash
# 1. Gate: everything healthy before merging anything
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -vE 'Running|Completed'
flux get kustomizations

# 2. Snapshot etcd on each node, and confirm the shutdown guard is in place
#    (see the header of apps/ansible/data/playbooks/configure-k3s-shutdown.yml)

# 3. Merge the PR that bumps `version:` in plan-k3s.yaml, then watch
kubectl get plan -n system-upgrade -w
kubectl get jobs,pods -n system-upgrade -o wide
kubectl logs -n system-upgrade -l upgrade.cattle.io/controller=system-upgrade-controller -f
```

Between nodes, etcd health is the gate. etcd is not scraped by Prometheus here, so ask each
apiserver directly rather than going through the VIP — all three must return `ok`:

```bash
kubectl --server "https://<node-ip>:6443" get --raw='/healthz/etcd'
```

### Stopping it

Reverting the PR is the correct stop, and Flux will prune the change within the reconcile interval.
If that is too slow, point the Plan at a selector nothing matches first, then revert — otherwise
Flux reconciles the patch away:

```bash
kubectl patch plan k3s-server -n system-upgrade --type=merge \
  -p '{"spec":{"nodeSelector":{"matchExpressions":[{"key":"nonexistent","operator":"Exists"}]}}}'
```

A Job that fails leaves its node **cordoned**, which is the intended behaviour — it stops the roll
rather than continuing onto a second node. Uncordon by hand once the cause is understood.

## Security footprint

Worth being deliberate about, since this is a controller that can restart the control plane.

- The **controller** runs non-root (65534), `allowPrivilegeEscalation: false`, all capabilities
  dropped, `RuntimeDefault` seccomp, with a scoped ClusterRole — jobs, nodes, plans, events, leases,
  plus a separate drainer role for pods and eviction. It is not cluster-admin.
- The **upgrade Jobs** are privileged and host-mount the node's root filesystem. That is inherent to
  replacing a binary in `/usr/local/bin`, and it is why the `system-upgrade` namespace ships
  labelled `pod-security.kubernetes.io/enforce: privileged`.
- With **no Plan present, no Job can be created.** The controller is inert between upgrades.

## Gotchas

- **Draining a control-plane node resets API connections.** kube-vip is a DaemonSet on all three, so
  the VIP fails over mid-drain and the drain reports `connection reset by peer`. Harmless, and
  documented in [Reclaiming Guest Disk Space](../misc/reclaiming-guest-disk.md).
- **The install script and this are different things.** Re-running `get.k3s.io` regenerates the
  systemd unit from whatever arguments it is given, silently losing any `INSTALL_K3S_EXEC` value not
  replayed. `rancher/k3s-upgrade` swaps the binary and leaves the unit alone. Confirm that on the
  first hop by diffing `/etc/systemd/system/k3s.service` before and after, rather than trusting it.
- **A Plan pinned to the version already installed is not a no-op.** No node carries the hash label
  yet, so the controller would still cordon, drain and run a Job on all three — the upgrade script
  would find nothing to do, but the disruption is real. Only add a Plan when you intend to move.
