<!-- docs/infrastructure/truenas.md -->
# TrueNAS

[TrueNAS](https://www.truenas.com) is an external network-attached storage (NAS) system providing centralized storage and data management services.

* **External Service:** `${LAN_PREFIX}.200:443`  
  Namespace: `truenas`
* **UI exposure:**  
  * `Service` with `EndpointSlice` pointing to external TrueNAS server.  
  * Ingress `truenas.${DOMAIN}` (TLS & Cloudflare DNS via external-dns).
* **Access:** HTTPS web interface for storage management and configuration.

| Feature | Status |
|---|---|
| Web UI | Available via `truenas.${DOMAIN}` |
| Storage pools | Managed via TrueNAS web interface |
| SMB/NFS shares | Configured on TrueNAS system |
| Backup services | Available via TrueNAS interface |
| NFS Provisioner | Available via `truenas-nfs-rwx` StorageClass |

## NFS Integration

The cluster includes an NFS provisioner that connects to the TrueNAS system for persistent storage:

* **Helm Chart:** `nfs-subdir-external-provisioner` v4.0.2
* **NFS Server:** `${LAN_PREFIX}.200` (same TrueNAS system)
* **NFS Path:** `/mnt/pool/k8s-nfs`
* **StorageClass:** `truenas-nfs-rwx` (not set as default)
* **Namespace:** `storage`

This allows Kubernetes workloads to use TrueNAS as persistent storage via NFS, providing ReadWriteMany (RWX) access for applications that need shared storage across multiple pods.

> **Note** - The web UI is an external service running outside the Kubernetes cluster, accessed via EndpointSlice routing through the ingress controller. The NFS provisioner runs inside the cluster and connects to the same TrueNAS system for storage.

## Troubleshooting

- [TrueNAS Docker Default Interface Fix](../misc/truenas-docker-default-interface.md) -- Resolving "Unable to determine default interface" when Docker/Apps fail to start.
