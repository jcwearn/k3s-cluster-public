# World Clock

[World Clock](https://github.com/jcwearn/world-clock) is a small static web
app for coordinating across timezones (built for wedding planning across
IST / US Eastern / US West Coast). Editing any clock's time pins a
hypothetical moment and converts it across all the other clocks; "Back to
live" resumes real-time ticking.

| Setting / Resource | Value |
|--------------------|-------|
| **URL**            | `https://clock.${DOMAIN}` |
| **Image**          | `ghcr.io/jcwearn/world-clock` |
| **Replicas**       | 1 (stateless) |
| **Namespace**      | `world-clock` |

### Manifests

* **Deployment** - unprivileged nginx serving the built SPA on port 8080.
* **Service** - ClusterIP; exposed only through the shared Envoy Gateway.
* **HTTPRoute** - `clock.${DOMAIN}` via `main-gateway` (wildcard TLS).

### Notes

* Clock configuration (timezones, labels, order, 12/24h) lives in each
  visitor's browser localStorage — no server-side state, no secrets, no
  ConfigMap.
* Releases are label-driven semver from the app repo; Renovate bumps the
  pinned image tag here.
