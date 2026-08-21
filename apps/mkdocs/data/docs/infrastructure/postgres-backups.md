# Postgres Backups

Nightly base backups and continuous WAL archiving for all three CloudNativePG clusters, to
Cloudflare R2, via the
[barman-cloud CNPG-I plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/).

## Why

Until 2026-08-20 none of these clusters had ever been backed up. Each runs at `instances: 1` —
no replica, no scheduled backup, no point-in-time recovery. A corrupted table or a mistaken
`DROP` was unrecoverable.

The data sits on the `truenas-nfs-postgres` StorageClass, so the risk was never hardware loss;
TrueNAS has its own redundancy. The risk is **corruption and accidental deletion**, and that is
precisely why the backups cannot also live on TrueNAS. Off-site is the whole point.

## Architecture

```
Cluster (instance pod)
  ├── postgres            ── archive_command ──┐
  └── plugin-barman-cloud ◀────────────────────┘
            │
            │ barman-cloud-wal-archive / barman-cloud-backup
            ▼
      Cloudflare R2  s3://k3s-postgres-backups/<cluster-name>/
```

The plugin runs as a sidecar in every instance pod, injected by the operator. `isWALArchiver:
true` on the Cluster's `plugins:` entry is what points Postgres' `archive_command` at it —
without that, base backups would exist with no WAL to replay onto them, and recovery would only
ever reach the last full backup.

Barman names the directory in the bucket after the **source cluster**, so all three share one
bucket and one `destinationPath` without colliding.

| Piece | Where it lives |
|---|---|
| Bucket `k3s-postgres-backups`, and the API token | `jcwearn/cloudflare-infra` (OpenTofu) |
| Plugin (HelmRelease, `cnpg-system`) | `infrastructure/cloudnative-pg/helmrelease-plugin-barman-cloud.yaml` |
| Per-cluster `ObjectStore`, `ScheduledBackup`, `PodMonitor` | `apps/<app>/` |
| Credentials | `apps/<app>/postgres-backup-secrets.sops.yaml`, one per namespace |
| Alert rules | `infrastructure/prometheus/helm.yaml`, group `postgres-backups` |

## Credentials

R2 does **not** accept a Cloudflare API token on its S3 API. It derives a key pair from one:

| S3 credential | Value |
|---|---|
| Access Key ID | the token's `id` |
| Secret Access Key | the **SHA-256 hash** of the token's `value` |

Both are computed as outputs in `cloudflare-infra`; retrieve them rather than deriving by hand.
Getting this wrong produces an authentication error that reads like a permissions problem.

The `ObjectStore` is namespaced, so **every namespace running a cluster needs its own copy** of
the Secret. Rotating means updating all of them — grep for `postgres-backup-r2` rather than
trusting memory of how many there are.

Three environment variables on the sidecar are load-bearing, not decoration:

```yaml
- name: AWS_REQUEST_CHECKSUM_CALCULATION
  value: when_required
- name: AWS_RESPONSE_CHECKSUM_VALIDATION
  value: when_required
- name: AWS_DEFAULT_REGION
  value: auto
```

barman-cloud rides on boto3, which since 1.36 sends integrity headers that non-AWS S3
implementations reject. Without the first two, uploads fail against R2 with an error that reads
like bad credentials. The OpenTofu state backend carries the same workaround as
`skip_s3_checksum`.

## Schedule

Staggered a quarter hour apart. All three read from the same NFS server and push over the same
uplink, so running them together would only have them contend.

| Cluster | Time | Retention |
|---|---|---|
| `n8n-database` | 02:00 | 30d |
| `paperless-ngx-database` | 02:30 | 30d |
| `immich-database` | 02:45 | 30d |

`ScheduledBackup.spec.schedule` is a **six-field Go cron with a leading seconds field**, not the
five-field Kubernetes CronJob form. `"0 0 2 * * *"` is 02:00; read as a CronJob schedule it
would mean something else entirely.

`immediate: true` is deliberately **not** set. Flux applies the ScheduledBackup and the
Cluster's `plugins:` block in the same reconcile, but the plugin only reaches the instance pod
once CloudNativePG has rolled it, roughly three minutes later. An immediate backup is requested
against the pod still running without the plugin and fails with `requested plugin is not
available` — harmless, self-correcting, and a permanent failed `Backup` object. Take the first
backup by hand instead; see below.

## Alert Rules

| Alert | Condition | For | Severity |
|---|---|---|---|
| `PostgresBackupStale` | newest base backup older than 36h | 1h | warning |
| `PostgresBackupFailing` | last-failed timestamp newer than last-available | 15m | critical |
| `PostgresBackupMissing` | no available backup at all | 6h | critical |

`Stale` allows 36 hours against a nightly schedule, so one missed run is tolerated before it
fires. WAL archiving may still be working when it does, in which case recovery is possible but
slower.

`Failing` compares the two timestamps rather than thresholding the failure one. A failure older
than the last success is a problem that has already resolved itself and should not page.

`Missing` is the rule that earns its place. Both timestamps read zero until a cluster's first
successful backup, so a cluster that has **never** been backed up looks identical to one that is
merely quiet — and `Stale` cannot see it, because its `> 0` filter drops the series. This is the
rule that catches a new cluster added without an `ObjectStore`.

> **Alert only on the `barman_cloud_cloudnative_pg_io_*` metrics.** CloudNativePG still exports
> `cnpg_collector_last_available_backup_timestamp` and `cnpg_collector_last_failed_backup_timestamp`,
> but they **stopped updating** when backups moved to the plugin and keep whatever value they
> last held. On this cluster the in-core metric reported zero available backups for a cluster
> with a good one, while its failure counterpart still reported a `Backup` object that had been
> deleted. Alerting on those names pages about healthy clusters and stays silent about broken
> ones.

A broken scrape is covered separately by `TargetDown` from `defaultRules`.

## Verification

Everything is healthy:

```bash
kubectl get cluster,objectstore,scheduledbackup,backup -A
kubectl get podmonitor -A -l release=kube-prometheus-stack
```

The `release: kube-prometheus-stack` label on each PodMonitor is load-bearing.
kube-prometheus-stack leaves `podMonitorSelectorNilUsesHelmValues` at its default of `true`, so
Prometheus selects only monitors carrying it. Without the label the object applies cleanly, is
never scraped, and every alert above silently never evaluates.

Confirm Prometheus is actually seeing the backup timestamps:

```bash
kubectl exec -n n8n n8n-database-1 -c postgres -- python3 -c "
import urllib.request
d = urllib.request.urlopen('http://localhost:9187/metrics', timeout=5).read().decode()
print('\n'.join(l for l in d.splitlines() if l.startswith('barman_cloud_')))"
```

## Taking a backup by hand

Needed after adding a cluster, and any time you want one now:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: n8n-database-adhoc
  namespace: n8n
spec:
  cluster:
    name: n8n-database
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl get backup -n n8n -w
```

An on-demand `Backup` is a one-shot record, so it is applied rather than committed. Typical
completion is 20–90 seconds for these databases.

## Restore runbook

**A backup you have never restored is a hypothesis.** This procedure was run end to end against
`n8n-database` on 2026-08-20: the restored cluster reached a healthy state in about 80 seconds,
and a row-count diff against the live database across all 126 tables came back empty.

Restore into a **scratch namespace**, never over the live cluster. Then compare, then delete.

### 1. Namespace and credentials

```bash
kubectl create namespace pg-restore-test

sops -d apps/n8n/postgres-backup-secrets.sops.yaml \
  | sed 's/namespace: n8n/namespace: pg-restore-test/' \
  | kubectl apply -f -
```

Piping keeps the values out of the terminal. **Never `sops -d` a credential to stdout** — in an
agent session that puts it in the transcript and forces a rotation.

### 2. An ObjectStore to read from

Copy the source app's `objectstore.yaml`, change the namespace and name, and **delete the
`retentionPolicy` line** so a throwaway cluster can never sweep the real archive. Flux is not
applying this one, so `$${R2_ENDPOINT}` has to be filled in by hand — read it out of the
`cluster-vars` Secret:

```bash
sops -d infrastructure/cluster-vars/secrets.sops.yaml | yq -r '.stringData.R2_ENDPOINT'
```

### 3. The restore cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: n8n-restore
  namespace: pg-restore-test
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  storage:
    size: 5Gi
    storageClass: truenas-nfs-postgres
  bootstrap:
    recovery:
      source: n8n-database-archive
  externalClusters:
    - name: n8n-database-archive
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: restore-source
          serverName: n8n-database
```

Three things that are easy to get wrong:

- **No `plugins:` block.** With `isWALArchiver` this throwaway cluster would archive its own WAL
  into the same bucket, beside the archive it is being restored from.
- **`serverName` names the source**, because that is the directory barman wrote to. It is not
  the name of the cluster being created.
- **`imageName` must match the source.** A recovery bootstrap replays the data directory rather
  than running `initdb`, so `postInitApplicationSQL` never fires. This matters most for
  `immich-database`, which runs `cloudnative-vectorchord` for the `vchord` extension —
  restoring it onto a stock postgres image gives a cluster that will not start.

### 4. Compare, then destroy

```bash
kubectl get cluster -n pg-restore-test -w   # wait for "Cluster in healthy state"

Q="select table_name, (xpath('/row/cnt/text()', query_to_xml(format('select count(*) as cnt from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint as rows from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by table_name;"

kubectl exec -n n8n n8n-database-1 -c postgres -- psql -U postgres -d n8n -At -F'|' -c "$Q" > /tmp/live.txt
kubectl exec -n pg-restore-test n8n-restore-1 -c postgres -- psql -U postgres -d n8n -At -F'|' -c "$Q" > /tmp/restored.txt
diff /tmp/live.txt /tmp/restored.txt && echo "identical"

kubectl delete namespace pg-restore-test
```

A non-empty diff is not automatically a failure — the live database keeps taking writes after
the backup was taken. Judge it by whether the drift matches what the application has been doing.

Deleting the namespace can sit in `Terminating` for several minutes on a `pvc-protection`
finalizer. That is normal for the NFS provisioner.

## Known gap

`immich-database` carries grants applied by hand — `pg_read_all_data`, `pg_read_all_stats` and
`REPLICATION` on the `immich` role — which are recorded only as comments in its manifest. Role
memberships live in the shared `pg_global` tablespace and a base backup covers it, so they
should return with a restore; the n8n test confirmed `pg_roles` came back intact. That is
reasoning rather than a measurement, so **spot-check it the first time immich is restored**.

## References

- [Barman Cloud CNPG-I plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/)
- [Object store providers, including the boto3 checksum workaround](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/)
- [CloudNativePG 1.30 — barmanObjectStore deprecation](https://cloudnative-pg.io/docs/1.30/appendixes/backup_barmanobjectstore/)
- [Cloudflare R2 API tokens and S3 credential derivation](https://developers.cloudflare.com/r2/api/tokens/)
- [Prometheus](prometheus.md) — where the alert rules live
