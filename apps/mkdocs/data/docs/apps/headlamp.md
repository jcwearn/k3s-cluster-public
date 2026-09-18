<!-- docs/apps/headlamp.md -->
# Headlamp

Extensible Kubernetes web UI for inspecting workloads, logs, ConfigMaps, etc.
Headlamp is maintained under sig-ui and replaces the archived kubernetes-dashboard.

* **Install:** Helm chart via Flux (`headlamp` namespace).
* **Access:** `https://dash.${DOMAIN}` (cluster-internal or via Tailnet).
* **RBAC:** two identities. Headlamp's own ServiceAccount holds the built-in `view`
  ClusterRole -- read everything, change nothing, no Secrets. A separate
  `headlamp-admin` ServiceAccount holds `cluster-admin` and has no stored token.

### Logging in

Read-only, the everyday login, from the long-lived token of the `view` account:

```bash
kubectl get secret headlamp-token -n headlamp \
  -o jsonpath='{.data.token}' | base64 -d | pbcopy
```

For a write session -- Helm operations, editing an object, deleting a pod -- mint a
token for the admin account. It expires on its own, and nothing with `cluster-admin`
is stored anywhere:

```bash
kubectl -n headlamp create token headlamp-admin --duration=8h | pbcopy
```

Paste either into Headlamp's token login. Tailscale is the boundary for reaching the
UI at all; the token is what decides what the session can do.

### Features

- Full cluster visibility with modern React UI
- Helm operations support (enabled)
- Plugin system for extensibility
- OIDC authentication support (optional)
