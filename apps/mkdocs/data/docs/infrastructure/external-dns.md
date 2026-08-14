# external-dns

[external-dns](https://github.com/kubernetes-sigs/external-dns)
keeps DNS records in sync with Kubernetes objects.

| Setting | Value |
|---|---|
| Provider | Cloudflare |
| Domain filter | `${DOMAIN}` |
| Sources | `crd`, `gateway-httproute` |
| Policy | `sync` |
| Helm version | `1.16.1` |

Cloudflare API token is injected from the sealed-/SOPS-encrypted
`cf-api-token` secret.

```yaml
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cf-api-token
        key: CF_API_TOKEN
```
