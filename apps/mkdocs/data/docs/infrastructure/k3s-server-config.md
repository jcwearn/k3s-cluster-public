# k3s Server Configuration

What the three control-plane nodes are told beyond the flags in their systemd unit, and how it
gets there. Two halves, deliberately split by where each can live:

| Half | Lives in | Applied by |
| --- | --- | --- |
| Things the cluster holds for k3s (today: the S3 credentials for etcd snapshots) | `infrastructure/k3s-server/` | Flux, like everything else |
| Things on the node's filesystem (`/etc/rancher/k3s/config.yaml.d/*.yaml`, and the two policy files under `/var/lib/rancher/k3s/server/`) | `apps/ansible/data/playbooks/configure-k3s-server.yml`, with the policy files in `apps/ansible/data/k3s/` | The `ansible-configure-k3s-server` CronJob, run by hand |

Flux cannot write to a node, and a node cannot be told to re-read its configuration without a
restart of k3s, which is why the second half is a supervised Ansible run rather than a reconcile.

## Why it exists

Every k3s argument on these nodes lives in the systemd unit's `ExecStart`, written by the install
script at bootstrap and described nowhere in Git. Anything that needs adding — and the
hardening roadmap on the [security page](../misc/security-hardening.md) has several things —
would mean editing a unit file by hand on three machines. k3s merges `/etc/rancher/k3s/config.yaml`
and every `config.yaml.d/*.yaml` with those flags at start, so drop-ins are the declarative form:
one file per concern, numbered for merge order, written by a playbook from Git.

## The drop-ins

### `10-etcd-s3.yaml` — off-site etcd snapshots

```yaml
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-s3
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 28
```

k3s snapshots etcd on its own; without this it only ever kept them on the node's own disk, so
losing the three guests lost the cluster's state with them. Now every snapshot is also uploaded
to the `k3s-etcd-snapshots` R2 bucket — every six hours, 28 kept, which is a week. Retention
applies to the bucket too; k3s prunes its own uploads.

The endpoint and credentials are **not** in the drop-in. k3s reads them from the
`kube-system/k3s-etcd-s3` Secret (`etcd-s3-config-secret`), which Flux manages from
`infrastructure/k3s-server/etcd-s3-secret.sops.yaml`. Rotating the token is a change to that
one encrypted file and touches no node. The bucket and token are created in
[`cloudflare-infra`](https://github.com/jcwearn/cloudflare-infra), whose README explains the
S3 derivation (Access Key is the token's id, Secret is the SHA-256 of its value) and which
outputs to copy. k3s wants the endpoint **without** a scheme.

Each scheduled and manual snapshot appears as an `ETCDSnapshotFile` object; the S3 ones carry a
`spec.s3` block:

```bash
kubectl get etcdsnapshotfile -o custom-columns='NAME:.spec.snapshotName,NODE:.spec.nodeName,S3:.spec.s3.bucket,READY:.status.readyToUse'
```

### `20-audit.yaml` — API audit log

```yaml
kube-apiserver-arg:
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
```

Every request the apiserver on that node handles is written, one JSON line each, to
`/var/lib/rancher/k3s/server/logs/audit.log`, under the policy the playbook installs from
`apps/ansible/data/k3s/audit-policy.yaml`. The policy's tiers, first match wins:

| Level | For |
| --- | --- |
| `None` | kube-proxy's watches, `leases`, `events`, and the health, version and metrics URLs |
| `Metadata` | `secrets`, `configmaps`, `serviceaccounts/token`, `tokenreviews` — who touched it, never what was in it. This rule sits above the write rule on purpose |
| `Request` | Every `create`, `update`, `patch`, `delete` and `deletecollection`: the body that was sent |
| `Metadata` | Everything else, which is reads |

**The log stays on the node.** Nothing ships it to a log store — there is no Loki here — so the
forensic question "who deleted that" is answered with `ssh` and `grep` on each of the three
servers, because a request lands on whichever apiserver the VIP or the client's connection reached.
It is not in `journalctl`. The apiserver rotates it at 100 MB, keeps ten files and drops anything
older than thirty days: about 1 GB per node at most.

```bash
# on a server: every write to Secrets in the last file, with who and when
grep '"resource":"secrets"' /var/lib/rancher/k3s/server/logs/audit.log \
  | grep -E '"verb":"(create|update|patch|delete)"' \
  | jq -r '[.requestReceivedTimestamp, .user.username, .verb, .objectRef.namespace, .objectRef.name] | @tsv'
```

### `30-psa.yaml` — a Pod Security default for unlabelled namespaces

```yaml
kube-apiserver-arg+:
  - admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml
```

Every namespace in Git carries its own `pod-security.kubernetes.io/*` labels
([security page](../misc/security-hardening.md)), and a label wins over any default, mode by mode.
This drop-in is the floor for the namespaces created outside Git — `default`, `flux-system`,
whatever comes next — which until now got no policy at all. The `AdmissionConfiguration` the
playbook installs from `apps/ansible/data/k3s/psa.yaml` sets `enforce: baseline`, `audit` and
`warn: restricted`, and exempts `kube-system`, whose pods are k3s's own.

The `+` matters. k3s loads the drop-ins in name order and a key in a later file replaces the
earlier value, lists included; `kube-apiserver-arg+` appends instead. `20-audit.yaml` owns
`kube-apiserver-arg`, and every later drop-in that adds an apiserver flag must write it with the
`+`, or the audit log silently goes away. After each restart the playbook reads the command line the
apiserver logged at start and fails the run if either flag is missing.

## Running the playbook

After a change to the playbook has merged:

```bash
kubectl -n ansible create job --from=cronjob/ansible-configure-k3s-server \
  configure-k3s-server-$(date +%s)
kubectl -n ansible logs -f job/configure-k3s-server-<ts>
```

For each node in turn it gates on every node Ready and etcd healthy on all three, writes the
drop-ins and policy files, and — only where a file actually changed — restarts k3s, waits for the
node to come back and etcd to answer on all three, checks the apiserver's logged command line for
both the audit and admission flags, waits for `audit.log` to be written, then takes a snapshot
named `configure-check`, waits for its `ETCDSnapshotFile` to show up with `spec.s3` and
`readyToUse: true`, and deletes it again. A node that will not come back stops the play there,
with the other two holding quorum; `journalctl -u k3s` on that node is the first look.

`systemctl restart k3s` restarts the supervisor and the apiserver on one node. containerd and
the pods keep running (the unit's `KillMode` is `process`), and the control-plane VIP moves to
another node for the seconds it takes. Nothing is drained.

To write the files and inspect them without restarting, copy the Job and append
`-e restart_k3s=false` to its args.

## Restoring from an off-site snapshot

Not written up until it has been rehearsed. The shape is k3s's documented
`k3s server --cluster-reset --cluster-reset-restore-path=<s3 name> --etcd-s3 ...` on one fresh
node, then rejoining the other two — and it needs the cluster's **server token**
(`/var/lib/rancher/k3s/server/token`, kept in the password manager), because the snapshot's
bootstrap data is encrypted with it.
