<!-- docs/infrastructure/truenas.md -->
# TrueNAS

[TrueNAS](https://www.truenas.com) is an external network-attached storage (NAS) system providing centralized storage and data management services.

* **External Service:** `${LAN_PREFIX}.200:443`  
  Namespace: `truenas`
* **UI exposure:** `apps/external/truenas/`  
  * Envoy Gateway `Backend` pointing at `${LAN_PREFIX}.200:443`, with
    `insecureSkipVerify` (the box serves a self-signed certificate) and
    `alpnProtocols: [http/1.1]`.
  * `HTTPRoute` for `truenas.${DOMAIN}` on the main gateway (TLS via
    cert-manager, DNS via external-dns).
  * A `BackendTrafficPolicy` raises the idle and request timeouts to 3600s.
* **Access:** HTTPS web interface for storage management and configuration.

| Feature | Status |
|---|---|
| Web UI | Available via `truenas.${DOMAIN}` |
| Storage pools | Managed via TrueNAS web interface |
| SMB/NFS shares | Datasets and NFS exports in [`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra); SMB still manual |
| Backup services | Available via TrueNAS interface |
| NFS Provisioner | Available via `truenas-nfs-rwx` StorageClass |

## NFS Integration

The cluster runs one `nfs-subdir-external-provisioner` per TrueNAS dataset, all
in the `storage` namespace, defined in `infrastructure/truenas-nfs/`. Each
provisioner creates and reaps a directory per PVC inside its dataset.

| StorageClass | Dataset | NFS path | Default |
|---|---|---|---|
| `truenas-nfs-rwx` | `k8s-nfs` | `/mnt/pool/k8s-nfs` | **yes** |
| `truenas-nfs-postgres` | `k8s-nfs-postgres` | `/mnt/pool/k8s-nfs-postgres` | no |
| `truenas-nfs-monitoring` | `k8s-nfs-monitoring` | `/mnt/pool/k8s-nfs-monitoring` | no |

`truenas-nfs-monitoring` is the only class that sets `mountOptions` — `nfsvers=4.1,hard`. NFSv4.1 has
integrated file locking, which is what makes running Prometheus' TSDB, Grafana's SQLite database and
Alertmanager's notification log on NFS defensible; see
[Prometheus](prometheus.md). `mountOptions` can only be set per StorageClass, which is the reason
this is a separate share rather than a directory on the shared one.

* **Helm Chart:** `nfs-subdir-external-provisioner` v4.0.18
* **NFS Server:** `${LAN_PREFIX}.200` (same TrueNAS system)

This allows Kubernetes workloads to use TrueNAS as persistent storage via NFS, providing ReadWriteMany (RWX) access for applications that need shared storage across multiple pods.

> **Note** - The web UI is an external service running outside the Kubernetes cluster, reached through the Envoy Gateway. The NFS provisioner runs inside the cluster and connects to the same TrueNAS system for storage.

## Configuration as code

Datasets, NFS exports and the NFS service are managed with OpenTofu in
[`jcwearn/truenas-infra`](https://github.com/jcwearn/truenas-infra), the way the
`pveum` monitoring user is recorded in
[Proxmox Monitoring](proxmox-monitoring.md). Changes go through plan-on-PR and
apply-on-merge, with a nightly drift check.

**Adding a dataset for the cluster is now two pull requests, and they are
ordered:**

1. In `truenas-infra`, add an entry to `local.k8s_nfs` in `k8s-nfs.tf`. Merging
   creates the dataset and its export with the same permissions as every other
   k8s export.
2. Here, add an `nfs-subdir-external-provisioner` HelmRelease under
   `infrastructure/truenas-nfs/`, with `nfs.path` matching
   `/mnt/pool/<dataset>`.

Doing them in the other order leaves PVCs `Pending` until the first one lands.
The two sides are not generated from each other; the path is the contract.

That repository also reaches this box through the `truenas.${DOMAIN}` route
above, so its CI depends on the gateway being healthy. If the cluster is down,
TrueNAS is managed by hand until it is back.

### Still manual

SMB shares, users, snapshot tasks, the Reporting Exporter and the SMTP settings
described in [TrueNAS Monitoring](truenas-monitoring.md) are not yet in
`truenas-infra` -- they exist on the box and are unmanaged, which is safe:
OpenTofu cannot destroy what it does not know about. Adopting them is Phase 4
of that repository's plan.

## Troubleshooting

- [TrueNAS Docker Default Interface Fix](../misc/truenas-docker-default-interface.md) -- Resolving "Unable to determine default interface" when Docker/Apps fail to start.
