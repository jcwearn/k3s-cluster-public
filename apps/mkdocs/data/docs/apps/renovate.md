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

The cache is an NFS-backed PVC (`renovate-cache-pvc`, 5Gi on `truenas-nfs-rwx`) mounted at
`/cache` and pointed at by `RENOVATE_CACHE_DIR`. It is what keeps a run at roughly three minutes
across 17 repos instead of cold-starting every datasource lookup.

!!! warning "Do not add a `chown` init container to guard it"
    One existed from April to August 2026 and ran `chown -R 1000:1000 /cache` on every tick. It
    reached **34 minutes** against three minutes of actual work — one serial NFS `SETATTR`
    round-trip per file, over a cache that grows without bound. Runs outlasted the 30-minute
    schedule, so `concurrencyPolicy: Forbid` chained them back-to-back and a Renovate pod was
    running against the NAS permanently.

    It never did anything. The init container inherits the pod's `runAsUser: 1000`, and a non-root
    uid cannot change a file's owner — the trailing `|| true` swallowed exactly that. What makes
    `/cache` writable is the provisioner creating the subdirectory `0777`, and Renovate is its
    only writer. That behaviour survived the move to `csi-driver-nfs`, which sets it explicitly as
    `mountPermissions: "0777"` rather than by default. `fsGroup` is not the mechanism either: this
    volume still uses an in-tree NFS mount, which kubelet reports as unmanaged, so it never applies
    it -- and the driver is configured with `enableFSGroupPolicy: false` so that stays true for new
    volumes too.

    The deadline was raised twice (1500 → 2400 → 2700) chasing the growth before the cause was
    found. Treat a rising `activeDeadlineSeconds` as a symptom to investigate, not a dial.

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
| `Pending` | **yes**, after 10m | Was excluded while the `chown` kept pods in `PodInitializing` for half an hour. Now a run is ~3 minutes, so `Pending` means something real: unschedulable, image pull stuck, or a PVC that will not bind because the NAS is down. |
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
