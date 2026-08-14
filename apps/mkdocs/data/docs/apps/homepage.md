<!-- docs/apps/homepage.md -->
# Homepage

**Homepage** is a modern, fully-static dashboard that surfaces the status of all your homelab services.

| Feature | How it’s used here |
|---------|-------------------|
| **Static & cached** | Fast — rendered once, served by Nginx (or any static host). |
| **YAML config** | Dashboard sections & widgets live in `ConfigMap homepage-config`. |
| **Service discovery** | Labels on K8s Services auto-populate cards (enabled via controller args). |
| **Routing** | `https://${DOMAIN}` via Envoy Gateway `HTTPRoute` (TLS via cert-manager wildcard). |
| **Auth** | BasicAuth secret mounted at `/etc/nginx/.htpasswd` (optional). |

## Apex domain DNS

Homepage is served on the apex domain `${DOMAIN}` (not a subdomain). This requires special DNS handling:

- **Subdomains** (e.g., `immich.${DOMAIN}`) use CNAME records pointing to `k3s-gateway.${TAILNET}` (the Tailscale hostname for the Envoy Gateway). The CNAME target is a Tailscale MagicDNS name that only resolves within the tailnet, but clients on Tailscale follow the CNAME and resolve it locally.
- **Apex domain** (`${DOMAIN}`) cannot use a CNAME with the same target because Cloudflare must "flatten" apex CNAMEs (resolve the target and return an A record). Since `k3s-gateway.${TAILNET}` doesn’t resolve from public DNS, flattening fails.

**Solution:** The Homepage HTTPRoute is labeled `external-dns/exclude: "true"` to exclude it from external-dns’s automatic CNAME creation. A separate `DNSEndpoint` CRD creates an A record pointing directly to the Tailscale IP of the gateway node. This is managed in `apps/homepage/dnsendpoint.yaml`.

If the Tailscale IP changes (e.g., after re-provisioning the gateway node), update the target in `dnsendpoint.yaml`.
