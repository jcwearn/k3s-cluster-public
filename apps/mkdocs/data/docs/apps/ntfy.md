# ntfy

Lightweight pub/sub push-notification broker.

| Kind | Image |
|---|---|
| Deployment | `binwiederhier/ntfy:v2.11.0` |

* Auth + topic ACLs stored in a ConfigMap (see manifest).
* Ingress `ntfy.${DOMAIN}` with WebSocket support enabled.

> **TODO** – note your token strategy or how automations publish messages.