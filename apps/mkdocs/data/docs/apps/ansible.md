# Ansible

Automated server management via Kubernetes CronJobs running Ansible playbooks.

## What it does

- **Weekly Linux updates:** Runs `apt dist-upgrade` on all Proxmox hypervisors and k3s VMs every Saturday at 3:00 AM. Sends an email summary reporting which hosts were updated and which need manual reboots.
- **Host onboarding:** One-shot playbook to create an `ansible` user, configure sudo, and deploy SSH keys on new hosts.
- **Node configuration:** On-demand playbooks for kernel sysctls, clean-shutdown ordering, and bounding the containerd image store by age.

## Architecture

- **Container image:** [`ghcr.io/jcwearn/ansible-runner`](https://github.com/jcwearn/ansible-runner) — custom slim image (~300MB) based on `python:3.12-slim` with `ansible-core` and `community.general` collection.
- **Playbooks & inventory:** Mounted as a ConfigMap via `configMapGenerator`.
- **Secrets:** SOPS-encrypted SSH private key and Gmail SMTP credentials.
- **No auto-reboots:** All reboots are manual. Email reports flag which hosts need attention.

## CronJobs

| Name | Schedule | Playbook |
|------|----------|----------|
| `ansible-update-linux` | Saturday 3:00 AM | `update-linux.yml` |
| `ansible-configure-node-sysctl` | suspended | `configure-node-sysctl.yml` |
| `ansible-configure-image-gc` | suspended | `configure-image-gc.yml` |
| `ansible-configure-k3s-shutdown` | suspended | `configure-k3s-shutdown.yml` |

Only the first runs on a schedule. The others are **suspended**, and carry a placeholder schedule of
`0 0 1 1 *` purely because a CronJob requires one — they exist to be triggered by hand when a node
needs (re)configuring, not to run periodically. Triggering one is the same
`create job --from=cronjob/...` as below.

`configure-image-gc` writes a kubelet config drop-in setting `imageMaximumGCAge: 168h`, so images
unused for a week are evicted regardless of disk pressure. It **does not restart k3s** — the setting
lands on each node's next restart. Two things about it are easy to get wrong:

- `imageMaximumGCAge` is a KubeletConfiguration field with **no command-line flag**. Setting it via
  `kubelet-arg` hands kubelet an unrecognised flag and k3s fails to start, so it has to be a drop-in
  (supported by k3s from v1.32).
- Kubelet's own image GC only runs under **disk pressure**, evicting from 85% down to 80% and no
  further. These nodes sat at 79–83% for months, so it never ran, and accumulated 244–318 images
  each against 73 referenced cluster-wide.

## Manual operations

**Trigger an update manually:**

```bash
kubectl -n ansible create job manual-linux --from=cronjob/ansible-update-linux
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
| `smtp-username` | Gmail address for sending reports |
| `smtp-password` | Gmail app password |

Edit with: `sops apps/ansible/secrets.sops.yaml`

## Files

```
apps/ansible/
  namespace.yaml
  serviceaccount.yaml
  cronjob-update-linux.yaml
  cronjob-configure-node-sysctl.yaml
  cronjob-configure-k3s-shutdown.yaml
  cronjob-configure-image-gc.yaml
  secrets.sops.yaml
  kustomization.yaml
  data/
    ansible.cfg
    inventory.yml
    playbooks/
      update-linux.yml
      onboard-host.yml
      configure-node-sysctl.yml
      configure-k3s-shutdown.yml
      configure-image-gc.yml
```
