# WithJoy Exporter (CronJob)

Daily export of the WithJoy guest list to a Google Sheet, with a `latest` tab
plus rolling dated history snapshots.

| Schedule | Timezone | Image | Source |
|---|---|---|---|
| `0 6 * * *` | `America/New_York` | `ghcr.io/jcwearn/withjoy-exporter` | [jcwearn/withjoy-exporter](https://github.com/jcwearn/withjoy-exporter) |

## How it works

WithJoy doesn't expose a server-side export endpoint, so this tool drives the
real UI: headless Chromium logs in via Auth0, clicks **Export All Guests**,
intercepts the resulting CSV, and pushes it to Google Sheets via a service
account.

## Manual trigger web UI

A small always-on Deployment (`withjoy-exporter-web`, same image running
`web.py`) serves a page for on-demand runs, with three actions:

* **Run export** — creates a `Job` from the CronJob's template via the
  Kubernetes API (RBAC-scoped ServiceAccount). Rejected while another run is
  in progress.
* **Sync schedule** — dispatches the `Refresh schedule index` workflow in
  [jcwearn/anupamaandjackson](https://github.com/jcwearn/anupamaandjackson),
  which reads the sheet this exporter writes and rebuilds the wedding site's
  schedule index.
* **Run both** — runs the export, then dispatches the workflow only if the
  export succeeded. A failed export would otherwise republish the schedule
  from a stale or half-written sheet.

The chain runs on a background thread, so closing the browser tab doesn't
abandon it; its state is in memory, so restarting the pod mid-chain loses it.
The page polls and reports the export Job and the workflow run separately.

* **Public URL**: `https://withjoy-exporter.${DOMAIN}` (via Envoy Gateway with TLS)
* **Tailscale**: `withjoy-exporter` hostname on the Tailnet
* **LoadBalancer IP**: `${LAN_PREFIX}.35` (via kube-vip)

## Column pinning

WithJoy briefly added `title` and `suffix` columns to the export and then
removed them, shifting every column to their right in the sheet each time. The
`withjoy-exporter-config` ConfigMap sets `EXPORT_COLUMNS` (loaded via `envFrom`
on the CronJob) to the exact column list, one per line, and the exporter takes
only those columns from the CSV, in that order.

A listed column missing from the CSV is written empty rather than dropped, so
positions never shift and the run still succeeds — it logs
`columns not found in export: ...`. Anything WithJoy sends that isn't listed is
dropped and logged as `ignoring undeclared export columns: ...`, which is the
early warning that they changed their schema again.

The generated `<tag> (tag)` columns are outside this list — selection runs
against the raw CSV, and tag expansion appends its columns afterwards. New tags
created in WithJoy surface on their own with no change here. `tags` itself must
stay in the list, since that's the column the expansion reads.

Editing the list is a plain edit to `apps/withjoy-exporter/configmap.yaml`; the
next scheduled or manually triggered run picks it up.

## Secrets

Three SOPS-encrypted Secrets back this app:

* `withjoy-exporter-env` — `WITHJOY_USERNAME`, `WITHJOY_PASSWORD`,
  `WITHJOY_GUEST_LIST_URL`, `SHEET_ID` (loaded via `envFrom` on the CronJob).
* `withjoy-exporter-google-credentials` — Google service account JSON,
  mounted at `/secrets/google-service-account.json` on the CronJob.
* `withjoy-exporter-github-app` — `GITHUB_APP_ID`,
  `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` for the schedule
  sync, as env vars on the web Deployment only.

The GitHub App holds a single repository permission, **Actions: read and
write**, and is installed on `jcwearn/anupamaandjackson` alone. It mints a
short-lived installation token per dispatch rather than storing a PAT. Rotate
by generating a new private key in the App's settings, `sops` the secret to
replace `GITHUB_APP_PRIVATE_KEY`, then delete the old key — Reloader restarts
the pod on its own.
