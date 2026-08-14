# Bootstrapping a 3-Node **k3s** Cluster on Ubuntu 24.04 LTS

> **Goal**
> Deploy a highly‑available k3s control‑plane that advertises a floating VIP via **kube‑vip**, then bootstrap Flux so the cluster pulls and reconciles the [`k3s‑cluster`](https://github.com/jcwearn/k3s-cluster) repo.

---

## 1 Install Ubuntu 24.04 on every node

| Choice | Why |
|--------|-----|
| **Server ISO** | Minimal footprint, no GUI bloat. |
| **LVM** | Lets us resize the root filesystem post‑install. |
| **Hostnames** | Use something obvious like `k3s‑01`, `k3s‑02`, `k3s‑03`. |

---

## 2 Post-install hardening — run on **all nodes**

```bash
# 2.1 Enable SSH (if disabled during install)
sudo systemctl enable --now ssh

# 2.2 Patch the box
sudo apt update && sudo apt upgrade -y

# 2.3 Grow the root LV to 100 % of the disk
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

---

## 3 Set up Git & SSH

```bash
ssh-keygen -t ed25519 -C "your@email.example"
cat ~/.ssh/id_ed25519.pub        # add this key to GitHub → Settings → SSH keys
git clone git@github.com:jcwearn/k3s-cluster.git ~/k3s-cluster
```

---

## 4 Pre-seed **kube-vip** manifests (all nodes)

```bash
sudo mkdir -p /var/lib/rancher/k3s/server/manifests
sudo ln -s \
  /home/$USER/k3s-cluster/infrastructure/kube-vip/kube-vip.yaml \
  /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
```

Placing the manifest in *auto‑deploy* ensures kube‑vip is running **before**
k3s publishes its API endpoint. Once Flux is running, it manages kube‑vip
going forward — the symlink is only needed for initial bootstrap.

---

## 5 Install k3s on the **first** node

```bash
VIP="10.0.0.5"    # pick a free IP on your LAN

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="
  server
  --cluster-init
  --tls-san=$${VIP}
  --disable servicelb
  --disable traefik
  --disable local-storage
" sh -
```

Record the bootstrap token:

```bash
sudo cat /var/lib/rancher/k3s/server/token
```

---

## 6 Join the **second & third** nodes

```bash
export K3S_TOKEN=<token-from-first-node>
VIP="10.0.0.5"

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="
  server
  --server https://$${VIP}:6443
  --disable servicelb
  --disable traefik
  --disable local-storage
" sh -
```

Add the token to your shell profile so it survives reboots:

```bash
echo "export K3S_TOKEN=$${K3S_TOKEN}" >> ~/.bashrc
source ~/.bashrc
```

---

## 7 Verify cluster health

```bash
kubectl get nodes
# k3s‑01, k3s‑02, k3s‑03   Ready
```

---

## 8 Prepare secrets for Flux + SOPS

1. **Generate an `age` key** (if you don't already have one):

   ```bash
   age-keygen -o ~/.age/age.key
   ```

2. **Create a GitHub PAT** with `repo` scope (fine‑grained or classic).
   Keep it handy for the next step.

---

## 9 Bootstrap Flux

```bash
flux bootstrap github \
  --owner=jcwearn \
  --repository=k3s-cluster \
  --branch=main \
  --path=clusters/prod \
  --personal
```

> Paste the GitHub PAT when prompted.

Once Flux pods are up, add the `age` key so it can decrypt SOPS‑encrypted
secrets:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.age/age.key
```

---

## 10 Done!

Flux will reconcile:

* **Infrastructure stack** → `clusters/prod/infrastructure.yaml`
  (TrueNAS NFS, cert‑manager, ingress‑nginx, Reloader, …)
* **Application stack**   → `clusters/prod/apps.yaml`
  (AdGuard Home, Homepage, Kubernetes‑Dashboard, …)

Grab a coffee — your fully‑GitOps, HA k3s homelab will be live in a few
minutes. ☕️🚀
