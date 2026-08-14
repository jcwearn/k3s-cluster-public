# Envoy Gateway

**Envoy Gateway** is the cluster's ingress controller, implementing the Kubernetes [Gateway API](https://gateway-api.sigs.k8s.io/) with Envoy proxy as the data plane.

* **Install:** Flux HelmRelease `envoy-gateway` `v1.7.0`
* **Service type:** `LoadBalancer` with kube-vip IP `${LAN_PREFIX}.5`
* **Tailscale hostname:** `k3s-gateway` (exposed via annotation on the proxy Service)

---

## Architecture

```
GatewayClass (envoy-gateway)
  └── Gateway (main-gateway, envoy-gateway-system)
        ├── http  listener  (port 80)  → global HTTP→HTTPS redirect
        └── https listener  (port 443) → wildcard TLS termination
              └── HTTPRoute (per app/service)
```

All HTTPRoutes across the cluster attach to the shared `main-gateway` in `envoy-gateway-system`. The Gateway handles TLS termination using the `wildcard-tls` wildcard certificate — individual routes do not configure TLS.

---

## Directory layout

The infrastructure is split into two Flux Kustomizations to handle CRD ordering:

```
infrastructure/envoy-gateway/
  ├── controller/          # Flux Kustomization: envoy-gateway
  │   ├── namespace.yaml
  │   ├── helmrepository.yaml
  │   ├── helmrelease.yaml
  │   └── kustomization.yaml
  └── config/              # Flux Kustomization: envoy-gateway-config (depends on controller)
      ├── envoy-proxy-config.yaml   # EnvoyProxy CRD (LoadBalancer, kube-vip IP, static service name)
      ├── gateway-class.yaml        # GatewayClass referencing EnvoyProxy config
      ├── gateway.yaml              # Gateway with HTTP + HTTPS listeners
      ├── certificate.yaml          # cert-manager Certificate for *.${DOMAIN}
      ├── http-redirect.yaml        # Global HTTPRoute for HTTP→HTTPS redirect
      └── kustomization.yaml
```

The controller must install Gateway API CRDs before GatewayClass/Gateway resources can be applied. `envoy-gateway-config` depends on `envoy-gateway` (controller).

---

## TLS

The wildcard certificate (`*.${DOMAIN}`) is configured once on the Gateway's `https` listener. Apps do **not** need any TLS configuration in their HTTPRoutes — they simply attach to the `https` listener by specifying `sectionName: https` in `parentRefs`.

---

## DNS

The Gateway has an `external-dns.alpha.kubernetes.io/target` annotation set to `k3s-gateway.${TAILNET}`. External-dns reads this annotation and creates CNAME records for every hostname in every HTTPRoute attached to the Gateway. Individual HTTPRoutes do **not** need DNS annotations.

### Apex domain exception

`${DOMAIN}` (the apex/root domain) uses a `DNSEndpoint` CRD with an A record instead of relying on the Gateway annotation. This is because external-dns cannot create the TXT ownership record for the bare domain within the Cloudflare zone. The DNSEndpoint is defined in `apps/homepage/`.

---

## HTTPS backends

For proxying to upstream services that use HTTPS (e.g., Proxmox, TrueNAS, UniFi), use the `Backend` CRD instead of a standard Service:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: example
  namespace: example
spec:
  endpoints:
    - ip: 192.168.x.x
      port: 443
  tls:
    insecureSkipVerify: true
    alpnProtocols:
      - "http/1.1"
```

Key points:

* `insecureSkipVerify: true` — required for self-signed upstream certs
* `alpnProtocols: ["http/1.1"]` — forces HTTP/1.1 during TLS handshake; without this, Envoy may negotiate HTTP/2 which breaks WebSocket `Upgrade` headers on backends that don't support RFC 8441

---

## WebSocket support

Envoy's default idle stream timeout is 5 minutes, which can close WebSocket connections prematurely. For services that use WebSockets, add a `BackendTrafficPolicy` with extended timeouts:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: example-timeouts
  namespace: example
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: example
  timeout:
    http:
      requestTimeout: 3600s
      idleTimeout: 3600s
    tcp:
      connectTimeout: 10s
```

---

## HTTP-to-HTTPS redirect

A global HTTPRoute attached to the `http` listener (port 80) returns a 301 redirect to HTTPS for all hostnames. This is defined in `config/http-redirect.yaml` and applies cluster-wide.
