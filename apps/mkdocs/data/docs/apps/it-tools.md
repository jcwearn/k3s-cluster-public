# IT-Tools

[IT-Tools](https://github.com/CorentinTh/it-tools) is a **Swiss-Army website**
for developers and sysadmins: JSON prettifier, JWT decoder, subnet calculator,
regex tester, and ~50 other gadgets — entirely in your browser.

| Setting / Resource | Value |
|--------------------|-------|
| **URL**            | `https://tools.${DOMAIN}` |
| **Image**          | `corentinth/it-tools:2024.10.22-7ca5933` |
| **Replicas**       | 1 (stateless) |
| **Ingress class**  | `nginx` |
| **Namespace**      | `it-tools` |

### Manifests

* **Deployment** - rolling update, 256 MiB RAM limit.
* **ServiceAccount** - minimal privileges (just Pods & ConfigMaps if future
  tools need them).
* **Ingress** - TLS via cert-manager; annotation
  `reloader.stakater.com/auto: "true"` so config tweaks restart Pods.

> **Fun fact:** The whole toolbox is a single static binary + HTML bundle —
> no DB, no server-side rendering.