<!-- docs/apps/headlamp.md -->
# Headlamp

Extensible Kubernetes web UI for inspecting workloads, logs, ConfigMaps, etc.
Headlamp is maintained under sig-ui and replaces the archived kubernetes-dashboard.

* **Install:** Helm chart via Flux (`headlamp` namespace).
* **Access:** `https://dash.${DOMAIN}` (cluster-internal or via Tailnet).
* **RBAC:** Uses built-in ClusterRoleBinding with `cluster-admin` access.

### Getting a login token

```bash
kubectl get secret headlamp-token -n headlamp \
  -o jsonpath='{.data.token}' | base64 -d | pbcopy
```

This copies the token to your clipboard. Paste it into the Headlamp login page.

### Features

- Full cluster visibility with modern React UI
- Helm operations support (enabled)
- Plugin system for extensibility
- OIDC authentication support (optional)
