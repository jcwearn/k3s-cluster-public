# Reloader

[Reloader](https://github.com/stakater/Reloader) automatically restarts Pods when
referenced **ConfigMaps** or **Secrets** change — perfect for hot-reloading
Nginx configs, Envoy certs, etc.

| Setting | Value |
|---------|-------|
| Chart version | `2.1.3` (example) |
| Mode | `auto` — watches all namespaces |
| Install NS | `reloader` |
| Flux object | `infrastructure/reloader/helmrelease.yaml` |

### Usage example

Annotate any Deployment, StatefulSet, or DaemonSet:

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```
