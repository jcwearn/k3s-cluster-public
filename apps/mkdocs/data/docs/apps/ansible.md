# Ansible

Automated server management via Kubernetes CronJobs running Ansible playbooks.

## What it does

- **Weekly hypervisor upgrades:** Runs `apt dist-upgrade` on each Proxmox host and the k3s VM it carries, one host at a time on Saturday mornings, and **reboots either or both when the packages call for it** — draining the k3s node first, shutting the VM down cleanly, and bringing it all back before the next host starts. Posts a per-host summary to ntfy. The full flow, its gate and what a failure leaves behind are in the [hypervisor upgrades runbook](../misc/hypervisor-upgrades.md).
- **LVM thin-pool metrics:** Re-asserts a node_exporter textfile collector on the Proxmox hosts weekly so metadata fullness is graphed and alerted.
- **Host onboarding:** One-shot playbook to create an `ansible` user, configure sudo, and deploy SSH keys on new hosts.
- **Node configuration:** On-demand playbooks for kernel sysctls, clean-shutdown ordering, and bounding the containerd image store by age.
- **Tailnet membership:** On-demand playbook that installs Tailscale on the hypervisors and the k3s guests and joins them as plain machines, so `ssh pve-01` resolves through MagicDNS from anywhere.

## Architecture

- **Container image:** [`ghcr.io/jcwearn/ansible-runner`](https://github.com/jcwearn/ansible-runner) — custom slim image (~300MB) based on `python:3.12-slim` with `ansible-core` and `community.general` collection.
- **Playbooks & inventory:** Mounted as a ConfigMap via `configMapGenerator`.
- **kubectl:** The upgrade Jobs mount `rancher/kubectl` as an [image volume](https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/) at `/opt/kubectl` — the image is a single static binary with no shell, so there is nothing to copy it out with, and the runner image is not rebuilt for it. The tag is pinned alongside the system-upgrade-controller's drain kubectl and moves with it.
- **RBAC:** `rbac.yaml` grants the `ansible-runner` ServiceAccount exactly what a cordon/drain/uncordon needs plus `/healthz/etcd`; every other playbook is SSH-only.
- **Secrets:** SOPS-encrypted SSH private key, an ntfy access token, and one healthchecks.io ping URL per hypervisor.

## CronJobs

| Name | Schedule (America/New_York) | Playbook |
|------|----------|----------|
| `ansible-upgrade-hypervisor-03` | Saturday 3:10 AM | `upgrade-hypervisor.yml -e target=proxmox-03` |
| `ansible-upgrade-hypervisor-02` | Saturday 5:40 AM | `upgrade-hypervisor.yml -e target=proxmox-02` |
| `ansible-upgrade-hypervisor-01` | Saturday 8:10 AM | `upgrade-hypervisor.yml -e target=proxmox-01` |
| `ansible-configure-lvm-thin-metrics` | Sunday 4:00 AM | `configure-lvm-thin-metrics.yml` |
| `ansible-configure-hypervisor-healthcheck` | Sunday 4:15 AM | `configure-hypervisor-healthcheck.yml` |
| `ansible-configure-proxmox-alloy` | Sunday 4:30 AM | `configure-proxmox-alloy.yml` |
| `ansible-configure-node-sysctl` | suspended | `configure-node-sysctl.yml` |
| `ansible-configure-image-gc` | suspended | `configure-image-gc.yml` |
| `ansible-configure-k3s-shutdown` | suspended | `configure-k3s-shutdown.yml` |
| `ansible-configure-k3s-server` | suspended | `configure-k3s-server.yml` |
| `ansible-enable-secrets-encryption` | suspended | `enable-secrets-encryption.yml` |
| `ansible-configure-tailscale` | suspended | `configure-tailscale.yml` |

The three upgrade Jobs are one per hypervisor rather than one loop, because the runner is a pod
inside the cluster it reboots — each is pinned by node affinity *off* the k3s node whose VM it will
shut down. They run in the order pve-03 → pve-02 → pve-01 (the host carrying the database primaries
last), two and a half hours apart; a run takes about 15 minutes and is killed at two. The
playbook's gate refuses to start while a sibling Job is active or the cluster is anything less
than whole, so the spacing is the order, not the lock.

The `configure-*` Jobs marked suspended carry a placeholder schedule of `0 0 1 1 *` purely because
a CronJob requires one — they exist to be triggered by hand when a node needs (re)configuring, not
to run periodically. Triggering one is the same `create job --from=cronjob/...` as below.
`configure-k3s-shutdown` matters more than it looks: the service it installs is what lets
`qm shutdown` finish instead of hanging on dirty NFS buffers, and the upgrade playbook refuses to
proceed on a guest that has lost it.

`configure-node-sysctl` raises the inotify limits and sets the six kernel parameters the kubelet
checks under `protect-kernel-defaults` (`vm.overcommit_memory`, `vm.panic_on_oom`, `kernel.panic`,
`kernel.panic_on_oops`, `kernel.keys.root_maxkeys`, `kernel.keys.root_maxbytes`), reading each back
afterwards. It must have run on every node before that flag is turned on — a kubelet that finds one
of them at another value refuses to start — and its values must never drift from the kubelet's
list. See [k3s server configuration](../infrastructure/k3s-server-config.md).

`configure-image-gc` writes a kubelet config drop-in setting `imageMaximumGCAge: 168h`, so images
unused for a week are evicted regardless of disk pressure. It **does not restart k3s** — the setting
lands on each node's next restart. Two things about it are easy to get wrong:

- `imageMaximumGCAge` is a KubeletConfiguration field with **no command-line flag**. Setting it via
  `kubelet-arg` hands kubelet an unrecognised flag and k3s fails to start, so it has to be a drop-in
  (supported by k3s from v1.32).
- Kubelet's own image GC only runs under **disk pressure**, evicting from 85% down to 80% and no
  further. These nodes sat at 79–83% for months, so it never ran, and accumulated 244–318 images
  each against 73 referenced cluster-wide.

`configure-k3s-server` is the one that **does restart k3s**, one node at a time. It writes the
k3s server configuration as drop-ins under `/etc/rancher/k3s/config.yaml.d/` and, where a file
changed, restarts k3s on that node, waits for it to be Ready and for etcd to answer healthy on all
three, then proves the change with a real snapshot before moving on. The drop-ins and what each
one is for are on the [k3s server configuration](../infrastructure/k3s-server-config.md) page.

`enable-secrets-encryption` is the other one that restarts k3s — twice per node — and it is a
procedure rather than a configuration: k3s's documented steps for turning on encryption of Secrets
at rest on a cluster that was started without it, in the order k3s says will not corrupt the
cluster. It was run once; every step is guarded by `k3s secrets-encrypt status`, so a second run
finds the work done and restarts nothing. The same page describes it.

`configure-tailscale` joins all six hosts to the tailnet. It installs Tailscale from the official
apt repo for the host's release (Debian on the hypervisors, Ubuntu on the guests), enables
`tailscaled`, and runs `tailscale up` only on a node whose `tailscale status --json` does not
already say `Running`, with every widening option pinned off: `--ssh=false`, no advertised routes,
`--advertise-exit-node=false`, `--accept-routes=false` and `--accept-dns=false` (the hosts keep
their own `resolv.conf`; on the k3s nodes that is what CoreDNS forwards to). The machine name is
Tailscale's default, the OS hostname — `pve-0N` for the hypervisors, `k3s-0N` for the guests — so
nothing about SSH changes except that the name now also resolves over the tailnet. If
`tailscale up` fails, the play reports its exit code and stderr; the auth key itself is never
logged. It prints `tailscale status` per host at the end. A second run on a joined host changes
nothing. Package updates are left to the weekly `upgrade-hypervisor` apt run;
`tailscale set --auto-update` is deliberately not turned on.

It needs a pre-auth key in `ansible-secrets` as `tailscale-authkey` — reusable, pre-authorized,
tagged, with an expiry — and fails on its first task with instructions if the key is absent. All six
hosts joined on 2026-10-14 as `tag:host`, after which the key was revoked and removed from the
secret; joining a new host means generating a fresh key and adding it back for that run.
Rollback on a host is `tailscale logout` plus removing the machine in the admin console.

To trigger it:

```bash
kubectl -n ansible create job ts-$(date +%s) --from=cronjob/ansible-configure-tailscale
```

A Proxmox host could later advertise the LAN routes as a fallback subnet router for when the
cluster's Connector is down; that is a separate change, not something this playbook does.

`configure-proxmox-alloy` ships each hypervisor's systemd journal to Loki (see
[Logging](../infrastructure/loki.md)). It installs Grafana Alloy from Grafana's apt repo, adds the
`alloy` user to `systemd-journal`, and writes `/etc/alloy/config.alloy` from
`data/alloy/host-journal.alloy.j2`, labelling streams `job="node-journal"`, `node="pve-0N"` like the
k3s nodes' journals. Alloy pushes to `loki-push`, the cluster's push-only receiver, over the
tailnet; the address comes from `tailscale ip -4 loki-push` on each run, because the hosts have
MagicDNS off and the 100.x address must not be written into the public repo. That lookup is also
the first thing to fail if the ACL grant (`tag:host` → `tag:log-ingest`, `tcp:3500`) is missing.
Alloy itself listens only on `127.0.0.1:12345`. It runs weekly, not suspended, so a rebuilt host
gets it back and a recreated receiver is followed; `HostJournalSilent` fires if a host stops
shipping.

## Manual operations

**Trigger a hypervisor upgrade manually** (on the LAN, never over Tailscale — a drain can sever it):

```bash
kubectl -n ansible create job upg-03-$(date +%s) --from=cronjob/ansible-upgrade-hypervisor-03
```

To pass extra vars — `dry_run=true` for apt in check mode with no drain, `force_reboot=host` or
`force_reboot=guest` to exercise a reboot path regardless of packages — splice them into the args:

```bash
kubectl -n ansible create job upg-03-dry --from=cronjob/ansible-upgrade-hypervisor-03 \
  --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].args += ["-e", "dry_run=true"]' \
  | kubectl apply -f -
```

**Onboard a new host:**

1. Get the SSH public key from the SOPS secret:

    ```bash
    sops -d apps/ansible/secrets.sops.yaml
    ```

    Copy the `ssh-public-key` value.

2. Copy it to the new host so Ansible can connect for the first time:

    ```bash
    ssh-copy-id -i /path/to/key.pub <USER>@<HOST_IP>
    ```

    Or manually append it to `~/.ssh/authorized_keys` on the host.

3. Get the ConfigMap hash (the suffix on the `ansible-data-*` name):

    ```bash
    kubectl get configmaps -n ansible
    ```

4. Run the onboard pod:

    ```bash
    kubectl -n ansible run onboard --rm -it \
      --image=ghcr.io/jcwearn/ansible-runner:<VERSION> \
      --restart=Never \
      --overrides='{
        "spec": {
          "containers": [{
            "name": "onboard",
            "image": "ghcr.io/jcwearn/ansible-runner:<VERSION>",
            "securityContext": {"runAsUser": 0},
            "command": ["ansible-playbook"],
            "args": [
              "/ansible/playbooks/onboard-host.yml",
              "-i", "<HOST_IP>,",
              "-e", "target_host=<HOST_IP>",
              "-e", "initial_user=<USER>",
              "-e", "initial_password=<PASSWORD>"
            ],
            "env": [{"name": "ANSIBLE_CONFIG", "value": "/ansible/ansible.cfg"}],
            "volumeMounts": [
              {"name": "ansible-data", "mountPath": "/ansible"},
              {"name": "ssh-key", "mountPath": "/secrets", "readOnly": true}
            ]
          }],
          "volumes": [
            {
              "name": "ansible-data",
              "configMap": {
                "name": "ansible-data-<CM_HASH>",
                "items": [
                  {"key": "ansible.cfg", "path": "ansible.cfg"},
                  {"key": "inventory.yml", "path": "inventory.yml"},
                  {"key": "onboard-host.yml", "path": "playbooks/onboard-host.yml"}
                ]
              }
            },
            {
              "name": "ssh-key",
              "secret": {
                "secretName": "ansible-secrets",
                "defaultMode": 256,
                "items": [
                  {"key": "ssh-private-key", "path": "ssh-private-key"},
                  {"key": "ssh-public-key", "path": "ssh-public-key"}
                ]
              }
            }
          ]
        }
      }'
    ```

    Replace `<VERSION>` with the current image tag, `<HOST_IP>` with the target IP, `<USER>` with the initial SSH user (e.g. `root`), `<PASSWORD>` with the sudo password (omit the arg if connecting as root), and `<CM_HASH>` with the hash from step 3.

5. After onboarding, add the host to `apps/ansible/data/inventory.yml` under the appropriate group.

## Secrets

Stored in `secrets.sops.yaml`:

| Key | Description |
|-----|-------------|
| `ssh-private-key` | SSH private key for the `ansible` user on managed hosts |
| `ssh-public-key` | SSH public key deployed to new hosts during onboarding |
| `ntfy-token` | Access token for a write-only ntfy user on the `hypervisor-upgrades` topic |
| `tailscale-authkey` | *Not present normally.* A reusable, tagged Tailscale pre-auth key, added only for a `configure-tailscale.yml` run and removed afterwards; mounted at `/secrets-tailscale/authkey` |

Edit with: `sops apps/ansible/secrets.sops.yaml`

## Files

```
apps/ansible/
  namespace.yaml
  serviceaccount.yaml
  rbac.yaml
  cronjob-upgrade-hypervisor-01.yaml
  cronjob-upgrade-hypervisor-02.yaml
  cronjob-upgrade-hypervisor-03.yaml
  cronjob-configure-lvm-thin-metrics.yaml
  cronjob-configure-hypervisor-healthcheck.yaml
  cronjob-configure-node-sysctl.yaml
  cronjob-configure-k3s-shutdown.yaml
  cronjob-configure-image-gc.yaml
  cronjob-configure-k3s-server.yaml
  cronjob-enable-secrets-encryption.yaml
  cronjob-configure-tailscale.yaml
  cronjob-configure-proxmox-alloy.yaml
  secrets.sops.yaml
  kustomization.yaml
  data/
    ansible.cfg
    inventory.yml
    playbooks/
      upgrade-hypervisor.yml
      onboard-host.yml
      configure-lvm-thin-metrics.yml
      configure-hypervisor-healthcheck.yml
      configure-node-sysctl.yml
      configure-k3s-shutdown.yml
      configure-image-gc.yml
      configure-k3s-server.yml
      enable-secrets-encryption.yml
      configure-tailscale.yml
      configure-proxmox-alloy.yml
    tasks/
      restart-k3s.yml
    scripts/
      lvm-thin-metrics.sh
      pve-reboot-required.sh
    alloy/
      host-journal.alloy.j2
    k3s/
      audit-policy.yaml
      psa.yaml
```
