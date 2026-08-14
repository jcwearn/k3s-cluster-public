# Refreshing Tailscale Machines  
*Fixing name clashes & stale node entries (e.g. `plex` vs `plex-1`)*

Occasionally two Services end up claiming the same Tailnet hostname, or an
old machine record sticks around after you re-create a Service.  
The cure is simply to **remove the Tailscale annotations, reconcile, then add
them back**.

---

## 1 Comment-out the annotations

```yaml
apiVersion: v1
kind: Service
metadata:
  name: plex
  namespace: media
  annotations:
    # tailscale.com/expose: "true"      ← comment out
    # tailscale.com/hostname: "plex"    ← comment out
spec:
  type: LoadBalancer
  ...
```

Commit & push (or open a PR if you're feeling fancy).

---

## 2 Reconcile via Flux

```bash
# Pull latest git commit
flux reconcile source git flux-system

# (Optional) see which Kustomizations are pending
kubectl get kustomizations -A

# Expedite specific reconciles if needed
flux reconcile kustomization apps
flux reconcile kustomization cert-manager-issuer
```

---

## 3 Verify in the Tailscale admin console

* The old machine entry for `plex` should disappear within \~30 seconds.
* Delete any lingering “Inactive” or duplicate nodes while you're there.

---

## 4 Re-add the annotations

Uncomment the two lines:

```yaml
annotations:
  tailscale.com/expose: "true"
  tailscale.com/hostname: "plex"
```

Push → reconcile again (steps **2.** above).

After the second reconcile Tailscale registers a fresh machine with the correct
name, certificate, and ACL tags.

> **That's it!**
> Think of it as a quick power-cycle for Tailnet entries—no Service spec changes,
> no pod restarts, just a fast annotation toggle.