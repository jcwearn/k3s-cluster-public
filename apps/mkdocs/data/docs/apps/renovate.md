# Renovate (CronJob)

Self-hosted Renovate. Keeps dependencies up-to-date across all the repos listed in its bot config by
opening PRs automatically.

| Schedule | Image | Bot config |
|---|---|---|
| `*/30 * * * *` | `renovate/renovate:*-full`, pinned by digest in `apps/renovate/cronjob.yaml` | `apps/renovate/data/renovate.json` |

* Authenticates as a GitHub App. The app ID, installation ID and private key are SOPS-encrypted in
  `apps/renovate/secrets.sops.yaml`; an init container exchanges them for a short-lived installation
  token.
* Output PRs trigger Flux reconciliation once merged.

## Two layers of config

| Layer | File | Applies to |
|---|---|---|
| Bot config | `apps/renovate/data/renovate.json` (ConfigMap) | Every managed repo, immediately |
| Shared preset | [`jcwearn/renovate-config`](https://github.com/jcwearn/renovate-config) `default.json` | Repos whose `renovate.json` extends it |
| Repo config | each repo's own `renovate.json` | That repo only; overrides the layers above |

Anything that should apply to *all* repos right away belongs in the bot config — it needs no change
to the individual repos. The shared preset is what each repo's `renovate.json` opts into, so changes
there reach only repos that extend it (but reach them without editing each repo).

## Onboarding a new repo

1. Add `jcwearn/<repo>` to the `repositories` array in `apps/renovate/data/renovate.json`.
2. Create the `dependencies` label in the repo — Renovate does not create labels, and a missing one
   is silently dropped:

    ```bash
    gh label create dependencies --repo jcwearn/<repo> \
      --color 0366d6 --description "Dependency updates"
    ```

3. Merge, and wait for the next run. Renovate opens a "Configure Renovate" onboarding PR.

The onboarding PR is **not** bare — the `onboardingConfig` key in the bot config makes Renovate write
this file instead, so there is nothing to hand-edit afterwards:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["local>jcwearn/renovate-config"]
}
```

`local>` resolves the preset on the current platform (GitHub). The preset repo must be readable by
the GitHub App installation — if it is not, preset resolution fails and aborts the whole repo run.

## What the shared preset sets

`config:best-practices` plus:

* `security:minimumReleaseAgePypi` — a 3-day delay before raising PyPI updates, matching what
  best-practices already does for npm. Worth having because non-major updates are automerged.
* `security:openssf-scorecard` — OpenSSF Scorecard badge column in PR bodies.
* `postUpdateOptions` — `npmDedupe`, `pnpmDedupe`, `gomodTidy`, `gomodUpdateImportPaths`. Each is
  read only by its own package manager, so all are inert on repos that don't use them.

Note that `config:best-practices` already enables weekly lock file maintenance (via
`:maintainLockFilesWeekly`), so repos do not need to declare `lockFileMaintenance` themselves.

!!! warning "Do not set a blanket `minimumReleaseAge`"
    `pin`, `bump`, `lockfileUpdate`, `rollback`, `replacement` and `lockFileMaintenance` updates
    carry no release timestamp. With the default `internalChecksFilter: "strict"`, a top-level
    `minimumReleaseAge` withholds them permanently. Digest and dependency pinning are load-bearing
    here, so use the scoped `security:minimumReleaseAge*` presets — they carry the necessary opt-out
    rules.

## Bot config highlights

* `automerge` + `autoApprove` for all `minor`/`patch`/`pin`/`digest` updates, grouped into a single
  "all non-major dependencies" PR per repo. Major updates always need manual review.
* `schedule` restricted to `* 0-7 * * 0,5,6` (overnight, Fri–Sun, `America/New_York`).
* `addLabels: ["dependencies"]` on every PR. This is `addLabels` rather than `labels` because
  `labels` is not mergeable and would replace the `security` label on vulnerability PRs.
* `vulnerabilityAlerts` enabled, plus `osvVulnerabilityAlerts` for advisories from osv.dev beyond
  GitHub's own, and an unresolved-CVE summary on each repo's Dependency Dashboard issue.
* `hostRules` throttles `api.github.com` to avoid secondary rate limits across 17 repos.
* `automerge` is turned back off for `jcwearn/cloudflare-infra` and `jcwearn/truenas-infra` via
  `matchRepositories`. Merging either runs `tofu apply` against live infrastructure, and neither
  repo has branch protection, so the `tofu plan` comment on each PR is the only review gate. On
  truenas-infra the `PjSalty/truenas` provider is pinned exactly on purpose — read the changelog
  and re-run the acceptance checks before merging a bump.

## Cache and job lifecycle

Renovate keeps a package cache at `RENOVATE_CACHE_DIR`, pointed at `/tmp/renovate/cache` — the
pod's `work-volume` `emptyDir`. **It does not persist between runs, deliberately.** The cache
still does its job within a run; it simply starts empty each tick.

### Why it is not on a PVC any more

It was, for 141 days, on a 5Gi RWX volume on `truenas-nfs-rwx`. It reached **34G**, about a third
of the entire shared `k8s-nfs` dataset. The measurements that ended it:

| | |
|---|---|
| Content blobs on disk | **917,627** |
| Live index entries the sweep could see | **749** |
| Live data those entries represent | ~29 MB, in 33 GB of storage |

Renovate's file cache is [cacache](https://github.com/npm/cacache), which is content-addressed
and append-only. Re-caching a key writes a *new* blob under a new integrity hash and appends a
new index entry; the previous blob is orphaned that instant. The shutdown sweep
(`FileCache.destroy()`) iterates the **index**, which returns one entry per key — so it does free
content, but only for the 749 keys it can see. Nothing reaches the rest. Only `cacache.verify()`
collects unreferenced content, and Renovate never calls it.

That leak is upstream and not fixable from here. What made it expensive was the PVC:

* **Nothing could measure it.** `kubelet_volume_stats_used_bytes` reports `statfs` of the NFS
  mount, so every NFS PVC in the cluster reports the same figure; and this volume was mounted
  about three minutes in every thirty on an in-tree `spec.nfs` PV, which emits no volume stats
  at all. 917k orphaned files accumulated for four months with nothing able to see it.
* **Nothing could clean it.** `cacache.verify()` and `rm -rf` both mean ~917k round-trips over
  NFS — the same shape as the `chown` below, which took 34 minutes over this same tree.
  Reclaiming it needed root on the TrueNAS web Shell, where the unlinks are local and take
  seconds.
* **Snapshots deferred the reclaim.** Wiping 34G moved 27.5 GiB from `usedbydataset` into
  `usedbysnapshots`; the pool only got it back as the hourly and daily tiers aged out.

### What persistence was actually buying

Measured with two identical dry runs over all 17 repos, one with the warm PVC cache and one with
no persistent cache at all:

| | warm | cold |
|---|---|---|
| Run time, 16 repos | 160.0s | 334.9s |
| HTTP requests | 667 | 1364 |
| `api.github.com` requests | 252 | 588 |
| Cache I/O | 116.3s (123ms/get, NFS) | 30.3s (25ms/get, local) |

So persistence was worth about **175s on an in-window tick** — and only there. Renovate's
`schedule` gate (`* 0-7 * * 0,5,6`) means most ticks skip branch and PR evaluation, which is
where most of the GitHub traffic goes. Measured outside the window the difference was **45s**
(2m05s against 2m49s).

!!! note "Rate limiting was checked, and is not the reason to persist"
    Doubling to 588 requests per in-window run is 1,176/hour at two ticks an hour — about **24%**
    of a 5,000/hour GitHub App budget, and that is the worst case. Secondary limits are about
    concurrency and burst rather than volume, and `hostRules` already caps
    `concurrentRequestLimit: 1` and `maxRequestsPerSecond: 8`; the cold run averaged 2.4 req/s.
    Neither diagnostic logged a 403, a 429 or an abuse warning. **The throttle is the
    rate-limit protection, not the cache.**

Against a 25-minute `activeDeadlineSeconds` on a 30-minute schedule, 45–175s is affordable. A
permanently growing NFS volume that nothing can measure, nothing can clean without root, and
whose leak is upstream's to fix, was not.

!!! warning "Do not add a `chown` init container"
    One existed from April to August 2026 and ran `chown -R 1000:1000 /cache` on every tick over
    the PVC. It reached **34 minutes** against three minutes of actual work — one serial NFS
    `SETATTR` round-trip per file, across what turned out to be 917,627 files. Runs outlasted the
    30-minute schedule, so `concurrencyPolicy: Forbid` chained them back-to-back and a Renovate
    pod was hitting the NAS permanently.

    It never did anything: the init container inherits the pod's `runAsUser: 1000`, and a
    non-root uid cannot change a file's owner — the trailing `|| true` swallowed exactly that.
    The deadline was raised twice (1500 → 2400 → 2700) chasing the growth before the cause was
    found. Treat a rising `activeDeadlineSeconds` as a symptom to investigate, not a dial.

### Where a run writes

Everything except the config and the token goes to `work-volume`, an `emptyDir` with
`sizeLimit: 4Gi`: cloned repos, the Renovate cache, and every package manager's cache.

`customEnvVariables` in the bot config points the tool caches there explicitly — `GOPATH`,
`UV_CACHE_DIR`, `NPM_CONFIG_CACHE`, `YARN_CACHE_FOLDER`, `YARN_GLOBAL_FOLDER` and pnpm's store
and cache dirs. That is **not** redundant now that `RENOVATE_CACHE_DIR` is itself ephemeral.
Without it `GOCACHE` and `GOMODCACHE` default into the container's writable layer, which no
`sizeLimit` bounds. And `GOBIN` is load-bearing regardless: the container args put
`/tmp/renovate/go-bin` on `PATH`.

`UV_CACHE_DIR` is there for a harder reason than the others, and it is the one to remember when
a new manager shows up. uv defaults to `$HOME/.cache/uv`, and `$HOME` is `/home/ubuntu` from the
image — not a mounted volume, and not writable by the pod's `runAsUser: 1000`. So uv did not
merely cache in the wrong place, it could not run at all:

```
error: Failed to initialize cache at `/home/ubuntu/.cache/uv`
  Caused by: failed to create directory `/home/ubuntu/.cache/uv`: Permission denied (os error 13)
```

That surfaced as an "Artifact update problem" on `jcwearn/resume` — the only repo in the fleet
with a `uv.lock`, so the uv path had never been exercised. Renovate bumped `pyproject.toml`,
failed to regenerate the lockfile, and opened the PR anyway; CI then failed on `uv sync
--locked` against the drift. **A manager whose cache is not redirected here does not degrade,
it fails**, and it fails one repo at a time as each new ecosystem is added.

Those overrides work because `getChildEnv()` merges
`{...extraEnv, ...parentEnv, ...globalConfigEnv, ...userConfiguredEnv, ...forcedEnv}` —
`customEnvVariables` is `globalConfigEnv`, so it outranks the directory each manager computed for
itself.

### Job settings

| Setting | Value | Why |
|---|---|---|
| `activeDeadlineSeconds` | `1500` (25 min) | Deliberately **under** the 30-minute schedule. Under `Forbid`, a job that outlives its own interval silently eats the next tick. |
| `backoffLimit` | `0` | No Kubernetes-level retry. PR state lives in GitHub and the next tick is ≤30 minutes away, so a retry only doubles the noise. |
| `ttlSecondsAfterFinished` | `86400` | Failed Jobs and their pods stay a day so there is something to read. This is for debugging, not alerting. |
| `failedJobsHistoryLimit` | `1` | One failed Job is enough to debug from. |

Because `backoffLimit` is `0`, **any node drain kills the run in flight** — a rolling k3s upgrade
will produce a failed job per hop. That is expected and self-correcting.

### What alerts, and what deliberately does not

`KubeJobFailed` is routed to `null` for the `renovate` namespace in the Alertmanager config. It is
a bare `> 0` gauge, so against a 24-hour TTL a single dead pod held it firing for a full day and
re-notified at the 12-hour repeat — one transient failure reading as a permanent outage.

`RenovateStale` replaces it: it fires when the CronJob has not *succeeded* in six hours (~12
consecutive missed runs). That is the honest question for a CronJob, it rides out a planned
node-drain window, and unlike any pod-phase rule it also catches a CronJob left suspended — for
instance by [the TrueNAS upgrade runbook](../misc/truenas-upgrade.md) and never resumed.

`KubernetesPodNotHealthy` keeps a Renovate-specific copy in
`infrastructure/prometheus/helm.yaml`, and the phase it leaves out has been inverted:

| Phase | Alerts? | Why |
|---|---|---|
| `Pending` | **yes**, after 10m | Was excluded while the `chown` kept pods in `PodInitializing` for half an hour. Now a run is ~3 minutes, so `Pending` means something real: unschedulable, or an image pull that is stuck. It no longer catches a PVC failing to bind, because there is no longer a PVC — the NAS being down does not stop a Renovate run at all now. |
| `Unknown` | yes, after 10m | The node is gone. |
| `Failed` | **no** | With `backoffLimit: 0` a failed run is normal and self-correcting, but the pod holds `Failed` for the full 24h TTL — so a gauge rule latches for a day off one transient event. `RenovateStale` is what catches failures that are not transient. |

The general rule excludes `namespace="renovate"` and this one covers it, which is why there are two
rules sharing the `KubernetesPodNotHealthy` name. The split is about *phases*, not about Renovate
being less important.


## Validating a config change

CI does this — `.github/workflows/validate-renovate.yaml`, which is path-filtered to
`renovate.json` and `apps/renovate/**` so unrelated pull requests do not pay its ~45s npm
install. That filter covers `cronjob.yaml` deliberately: the validator's version is read from
the CronJob image, so Renovate's own image bumps re-trigger the check and re-validate the
config against the version they introduce, rather than merging a deprecation unnoticed.

It validates the two files differently, which is the part worth knowing about:

| File | Kind | Validated as |
|---|---|---|
| `apps/renovate/data/renovate.json` | Global self-hosted config | global (the default) |
| `renovate.json` (repo root) | Repo config | repo, via `--no-global` |

That split is load-bearing. Without `--no-global` the root config is validated as global config,
which is a *superset* — so a global-only option accidentally put there (`binarySource`,
`hostRules`, `repositories`) passes validation and is then silently ignored by the bot at runtime.
`--strict` additionally fails when a config migration is needed; plain warnings, including
deprecations, already exit non-zero on their own.

To run it locally before pushing, against the same version:

```bash
version=$(grep -o 'renovate/renovate:[^@-]*' apps/renovate/cronjob.yaml | cut -d: -f2)

npx --yes --package "renovate@$version" renovate-config-validator \
  --strict apps/renovate/data/renovate.json
npx --yes --package "renovate@$version" renovate-config-validator \
  --strict --no-global renovate.json
```

!!! note "This is the check that catches the quiet failures"
    A misspelled option is valid JSON. It builds, it renders, it reconciles — and Renovate then
    discards it behind a `WARN` that only exists in pod logs. A deprecated `dockerUser` sat in the
    bot config that way until someone read the logs for an unrelated reason.
