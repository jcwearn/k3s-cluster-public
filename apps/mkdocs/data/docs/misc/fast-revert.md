# Fast Revert

What to do in the first five minutes after a merge breaks something. Everything on this cluster
is production and there is no staging, so the safety net is that undoing a change is one command
and Flux does the rest.

## How you find out

Two signals, both on ntfy:

- **`Flux reconciliation failed`** — a Kustomization could not apply or its resources never
  became healthy. Flux posts this to Alertmanager on every retry (once a minute), so it keeps
  firing while the problem lasts and resolves itself about five minutes after the last failure.
- **The app's own alert** — a `KubePodCrashLooping`, a blackbox probe, `TargetDown`.

A merge that applies cleanly but breaks behaviour produces only the second kind. A merge that
does not apply at all produces only the first, and nothing on the cluster has changed yet.

## First look

```bash
flux get kustomizations                 # which one is not Ready, and its one-line reason
flux get helmreleases -A                # if the reason names a HelmRelease
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n <ns> describe pod <pod> | tail -20   # events: probe failures, image pulls, mounts
```

`flux get kustomizations` is the whole story more often than not. Its message is the API
server's or the health check's exact complaint.

## Revert the merge

The change is a commit on `main`; the undo is its inverse, merged the same way.

```bash
git checkout main && git pull
git checkout -b fix/revert-<what>
git revert <sha>                # PRs squash-merge here, so the merge is one ordinary commit
                                # (a true merge commit would need `-m 1`)
git push -u origin HEAD
gh pr create --fill             # then merge it yourself; nothing goes to main without a PR
```

Then do not wait ten minutes for the poll:

```bash
flux reconcile source git flux-system
flux reconcile kustomization apps         # or whichever Kustomization owns the change
```

Flux applies the previous manifests and the Deployment rolls back to the previous ReplicaSet.
`kubectl rollout undo` is pointless here — Flux would re-apply the broken spec within ten minutes.

The revert goes through the same CI as any other change. If CI itself is what broke, push the
revert with the checks red and fix CI afterwards; a broken gate must not hold a rollback hostage.

## Freeze instead of revert

When the fix is known and small, pausing Flux buys time without touching Git:

```bash
flux suspend kustomization apps
# ... make the imperative fix, verify ...
flux resume kustomization apps      # reconciles immediately; make sure Git agrees first
```

Anything done imperatively while suspended is overwritten on resume, so the same fix has to be
merged before resuming, or the resume reintroduces the problem.

## A HelmRelease that is stuck

A HelmRelease that failed an upgrade retries a few times and then stops, with a message about
retries exhausted. A merged fix does not restart it on its own:

```bash
flux reconcile helmrelease <name> -n <ns> --force     # try the current spec again
flux reconcile helmrelease <name> -n <ns> --reset     # clear the retry counter, then reconcile
```

`helm rollback` by hand only makes sense with the HelmRelease suspended, and Flux will redo
whatever Git says on resume, so it is a diagnostic tool rather than a fix.

## What a revert does not undo

- **A database migration.** Reverting the image after a chart or app upgrade ran a schema
  migration leaves the old code against the new schema. Check the app's release notes before
  reverting a version bump on n8n, paperless-ngx, immich or job-track. The
  [Postgres backups](../infrastructure/postgres-backups.md) page has the restore runbook.
- **Data written by the new version** into a PVC in a format the old one does not read.
- **A pruned resource.** Prune deletes what left Git; the revert recreates the object, but a
  PVC recreated is an empty PVC. `prune: true` is set on every Kustomization here.
- **A node-level change** made by an ansible CronJob. Those are reverted by running the playbook
  again with the old values, not by Flux.

## After

Record what broke and why in the PR that reverts, so the retry does not repeat it. If a check in
CI or a hook could have caught it, that is the follow-up.
