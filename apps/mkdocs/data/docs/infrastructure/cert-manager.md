# cert-manager

[cert-manager](https://cert-manager.io) automates ACME certificate
issuance with Let’s Encrypt.

* **Install:** Flux HelmRelease `cert-manager` (`v1.17.2`)  
  CRDs are installed + kept up-to-date.
* **ACME issuer:** a **`ClusterIssuer`** (see `/cert-manager-issuer/`) that uses
  **Cloudflare DNS-01**.
* **Extra args** in `values.yaml` tell cert-manager to use Cloudflare’s
  recursive resolvers only (`1.1.1.1, 8.8.8.8`) to avoid split-DNS issues.

| Why it matters | Notes |
|---|---|
| Wild-card `*.${DOMAIN}` | Default TLS for Envoy Gateway. |
| Automatic renewals | Flux just reconciles – no cronjobs required. |

> **TODO** – document any “staging” issuer or additional issuers you add later.
