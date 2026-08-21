<!-- docs/infrastructure/csi-driver-nfs.md -->
# csi-driver-nfs

[csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) is the CSI
driver that provisions every persistent volume in the cluster, backed by the
three NFS shares on [TrueNAS](truenas.md).

| Setting | Value |
|---------|-------|
| Chart version | `4.13.4` |
| Provisioner | `nfs.csi.k8s.io` |
| Install NS | `csi-driver-nfs` |
| Flux object | `infrastructure/csi-driver-nfs/helmrelease.yaml` |
| StorageClasses | `truenas-nfs-rwx` (default), `truenas-nfs-postgres`, `truenas-nfs-monitoring` |

It replaced `nfs-subdir-external-provisioner` in August 2026. That chart was last
released in March 2023 and its image had not been re-tagged since 2021, while it
was the sole provisioner behind the default StorageClass on a cluster where
`--disable local-storage` means there is no fallback. It also used the
deprecated `Endpoints` API for leader election, which the 1.33 upgrade made
noisy. The full reasoning and the migration record are in
`docs/plans/csi-driver-nfs-migration/`.

The on-disk layout did not change: both drivers create one directory per volume
inside a share, so the existing directories were adopted as-is with no data
movement.

## StorageClasses

The three classes are plain manifests in `infrastructure/csi-driver-nfs/`, not
chart output (`storageClass.create: false`). This is deliberate. A
StorageClass's `provisioner`, `parameters`, `reclaimPolicy` and
`volumeBindingMode` are **immutable**, so a Helm-owned class could never be
edited again without the release failing with no way back. As kustomize-owned
objects carrying `kustomize.toolkit.fluxcd.io/force: "Enabled"`, Flux deletes
and recreates them instead. `mountOptions` is the exception — it is mutable, so
the monitoring class's `nfsvers=4.1` can be changed in place.

See [TrueNAS](truenas.md) for the share-to-class mapping and for the two-PR
procedure when adding a dataset.

!!! warning "The `$$` in `subDir` is not a typo"

    `infrastructure/csi-driver-nfs/` has Flux variable substitution enabled. A
    braced `$${...}` that is not one of the cluster variables is replaced with an
    **empty string, silently** — so an unescaped `subDir` renders as `--` and
    every volume in the cluster collides on a single directory. Neither CI nor
    `flux envsubst --strict` can see this. After editing any StorageClass, run
    `kustomize build infrastructure/csi-driver-nfs | flux envsubst` and read the
    rendered `subDir` with your eyes.

## Values that are not chart defaults

Four, and each is a silent regression if removed. They are commented inline in
the HelmRelease.

| Value | Why |
|---|---|
| `driver.mountPermissions: "0777"` | The chart default is `0`, meaning "do not chmod". The previous provisioner created every directory `0777`, and the apps running as a non-root UID depend on it. Without this the first new volume is unwritable. |
| `feature.enableFSGroupPolicy: false` | The default sets `CSIDriver.fsGroupPolicy: File`, making kubelet walk the whole volume chowning it on every mount. The in-tree NFS plugin reported its mounts unmanaged, so `fsGroup` has never applied here. Enabling it would stall `immich-library` (100 Gi, over NFS) before its pod may start. |
| `controller.enableSnapshotter: false` | On by default; needs VolumeSnapshot CRDs the cluster does not have. The driver's snapshots are tar files written back to the same share, which is not a backup worth having beside CloudNativePG's WAL archiving. |
| `storageClass.create: false` | See above. |

The resulting `CSIDriver` reports `fsGroupPolicy: ReadWriteOnceWithFSType`,
which reads like something was left enabled but is the correct outcome: kubelet
applies `fsGroup` only to `ReadWriteOnce` volumes that declare a filesystem
type, and NFS volumes declare none.

## Legacy volumes

Volumes created before the migration still carry an in-tree `spec.nfs` source
and a `pv.kubernetes.io/provisioned-by: cluster.local/truenas-nfs-*` annotation.
They mount, remount and reschedule normally — kubelet mounts NFS itself, and the
annotation is inert. There is no CSI migration path for in-tree NFS and no
removal date, so this is stable rather than a grace period.

One consequence: deleting one of those PVCs leaves its PV `Released`
indefinitely, because the controller waits for an external provisioner that no
longer exists. It is not stuck on a finalizer — `kubectl delete pv <name>`
succeeds immediately — but the directory is left on the share un-renamed rather
than archived.

## Troubleshooting

```bash
kubectl -n csi-driver-nfs get pods -o wide
kubectl -n csi-driver-nfs logs ds/csi-nfs-node -c nfs --tail=50
kubectl get csidriver nfs.csi.k8s.io -o yaml
```

The check worth knowing is `csinode`:

```bash
kubectl get csinode -o 'custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name'
```

All three nodes must list `nfs.csi.k8s.io`. It is the only real proof that the
kubelet plugin directory resolves correctly — if it does not, the registrar
never registers and every other signal still looks healthy while no volume can
mount. Re-run it after any node upgrade.
