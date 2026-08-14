**Securing Kubernetes cluster**

Below is the approach I use when taking a **fresh, production-bound cluster** (Flux-managed K3s, TrueNAS NFS Storage, SOPS-encrypted secrets) from "it works" to "it's hardened".  Treat it as a layered program: each layer reduces blast-radius, adds guard-rails, or tightens least-privilege.

---

## 1. Threat-model first 📋

| Layer             | Typical Risks                               | Questions to ask yourself                                            |
| ----------------- | ------------------------------------------- | -------------------------------------------------------------------- |
| **Control-plane** | API-server abuse, credential leakage        | Who can reach the API at all? How are kubeconfigs rotated & scoped?  |
| **Workloads**     | Lateral movement, container escape          | Do Pods run as root? Is hostPath blocked? Are node ports exposed?    |
| **Network**       | East/west traffic snooping, noisy neighbors | Which Pods actually need to talk? Which *ports*?                     |
| **Data**          | Secret leakage, PVC theft                   | Are volumes encrypted? Do backups leak?                              |
| **Supply chain**  | Malicious images/manifests                  | Do I trust every `docker pull` in YAML? Are images signed & scanned? |

Keep that table in mind as we tighten each layer.

---

## 2. Cluster-wide baseline

| Area                      | Harden it by ...                                                                                                                                                                        | Why it matters                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| **Patch & lock down K3s** | • Upgrade to latest K3s patch.<br>• Disable **anonymous-auth**, set `--authorization-mode=RBAC` only.<br>• Turn on audit-logs (K3s: `/var/lib/rancher/k3s/server/audit-policy.yaml`). | Remove low-hanging fruit & gain forensics.                     |
| **Admission control**     | • **PodSecurityAdmission**: cluster-level `restricted` <br>• Deploy OPA/Gatekeeper or Kyverno with CIS policies (no hostPID, hostPath, runAsNonRoot, etc.)                            | Enforce build-time + runtime policy consistently via GitOps.   |
| **Image provenance**      | • Scan images (Trivy, Grype) in CI.<br>• Sign & verify with **cosign** (`cosign verify`) via Gatekeeper policy.                                                                       | Stops "works on my laptop, pwns in prod" supply-chain attacks. |
| **Secrets**               | • Keep SOPS-encrypted at rest in Git.<br>• Convert high-value items to **External Secrets** or **Vault Agent Injector**.                                                              | K8s secrets are base64 only; defence-in-depth needed.          |

---

## 3. Namespace & RBAC design

1. **One app → one namespace** (plus a shared `infra` or `platform` namespace for things like envoy-gateway, cert-manager).
2. **Flux**: point each `Kustomization` at the namespace path; include a `decryption` stanza *inside* that Kustomization so secrets aren't reapplied in plaintext.
3. **ServiceAccount-per-workload**

   * *Never* let Pods run as `default` SA.
   * Bind a **Role**, not ClusterRole, unless cluster-scope APIs are truly needed (cert-manager, ingress controllers, operators).

```yaml
# apps/foo/roles.yaml  (applied by Flux)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: foo-reader
  namespace: foo
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]   # only its own namespace scope
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: foo-read-bind
  namespace: foo
subjects:
  - kind: ServiceAccount
    name: foo     # referenced in Deployment.spec.template.spec.serviceAccountName
roleRef:
  kind: Role
  name: foo-reader
  apiGroup: rbac.authorization.k8s.io
```

> **Tip:** Use **kubescape** or `rakkess` to audit what each SA can actually do.

---

## 4. Pod security context & runtime constraints

Add these to every `Deployment`/`StatefulSet` via a Kustomize patch that your Gatekeeper policy also enforces:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: ["ALL"]
```

If a container *has* to bind 80/443, use an **initContainer + iptables** or **NET\_BIND\_SERVICE** capability in isolation rather than letting the main container run as root.

---

## 5. Network isolation (default-deny first)

1. Install a CNI that supports policies (Calico, Cilium, etc.).
2. Apply a cluster default-deny *except* kube-system.
3. For each namespace, permit only necessary egress/ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-envoy-gateway
  namespace: foo
spec:
  podSelector: {}                     # all Pods in foo
  policyTypes: ["Ingress","Egress"]
  ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: envoy-gateway-system
        podSelector:
          matchLabels:
            gateway.envoyproxy.io/owning-gateway-name: main-gateway
    ports:
      - port: 8080
        protocol: TCP
  egress:
  - to:
      - ipBlock:
          cidr: 0.0.0.0/0             # if outbound Internet is truly needed
    ports:
      - port: 443
        protocol: TCP
```

This prevents east-west chats unless explicitly opened.

---

## 6. Storage & TrueNAS considerations

| Hardening step         | How                                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| **Backups**            | Store backups off-cluster with TLS (e.g., S3 HTTPS). Encrypt bucket-side.                          |
| **Access**             | RBAC: only the TrueNas manager ServiceAccount gets `storage.k8s.io` verbs on `persistentvolumes`. |

---

## 7. Ingress, certificates & external exposure

* Use **cert-manager** with Let's Encrypt; require TLS everywhere (HSTS).
* Annotate ingresses with security headers (Flux patch).
* If acceptable, front everything with **Cloudflare Tunnel** or **Tailscale funnel** instead of public LB.

---

## 8. Supply-chain guard-rails in GitOps

| Stage            | Guard-rail                                                                       |
| ---------------- | -------------------------------------------------------------------------------- |
| **Pull-request** | Trivy scans, OPA policy test (`conftest test`), `kubeconform` schema validation. |
| **Merge→main**   | Flux applies; Gatekeeper blocks non-compliant objects before they hit etcd.      |
| **Runtime**      | Falco or Cilium Tetragon for syscall anomaly detection.                          |

---

## 9. Observability & audit

* **Audit-logs** ship to Loki/Grafana with retention ≥ 90 days.
* Enable **TrueNAS NFS Monitoring** dashboards - watch for `FailedMount`, `Evicted` events (often signal privilege issues).
* Run **kube-bench** & **kube-hunter** monthly under a CronJob and post to Slack/Gotify.

---

## 10. Summary checklist ✅

1. **\[ ]** Updated K3s & disabled anonymous-auth.
2. **\[ ]** PodSecurityAdmission = *restricted* (rootless, seccomp, no hostPath).
3. **\[ ]** OPA/Kyverno policies in Git; Gatekeeper blocking at admission.
4. **\[ ]** Namespaces = one per app; default-deny NetworkPolicy.
5. **\[ ]** ServiceAccount per workload + Role (namespace-scoped).
6. **\[ ]** TrueNAS encryption + restricted RBAC.
7. **\[ ]** Ingress TLS only; global WAF/CDN if possible.
8. **\[ ]** CI scans & image signatures verified in-cluster.
9. **\[ ]** Centralized audit-logs; automated CIS benchmark scans.

Adopt the habit of **proving a new permission is necessary** (observed failure, then permit the exact verb/resource/port) rather than *guessing*.  With GitOps that's just another PR - and your future self will thank you for the paper trail.
