# Renovate (CronJob)

Self-hosted Renovate. Keeps dependencies up-to-date across all the repos listed in its bot config by
opening PRs automatically.

| Schedule | Image | Bot config |
|---|---|---|
| `*/30 * * * *` | `renovate/renovate:44.30.3-full` | `apps/renovate/data/renovate.json` |

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
* `hostRules` throttles `api.github.com` to avoid secondary rate limits across 14 repos.

## Validating a config change

```bash
docker run --rm -v "$PWD/apps/renovate/data/renovate.json:/c.json:ro" \
  renovate/renovate:44.30.3-full renovate-config-validator /c.json
```
