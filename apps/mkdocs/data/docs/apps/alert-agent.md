# alert-agent

[alert-agent](https://github.com/jcwearn/alert-agent) is the cluster's **alert
triage agent**. Alertmanager sends it every alert that reached ntfy and Slack.
It records each one as an incident, and in later phases it runs Claude Code
headless against the incident: it fixes low-risk problems through a fixed set
of reversible actions and opens a pull request for anything larger.

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| **URL**            | `https://alert-agent.${DOMAIN}`           |
| **Image**          | `ghcr.io/jcwearn/alert-agent`             |
| **Database**       | PostgreSQL 16 (CloudNative-PG)            |
| **Storage**        | None — all state is in Postgres           |
| **Ingress**        | Envoy Gateway HTTPRoute (UI only)         |
| **Namespace**      | `alert-agent`                             |

The design and phase plan are in `docs/plans/alert-agent/` in this repo.

## Status

Phase 2 is live: every new incident gets a **read-only diagnosis** by Claude
(Opus, on the Claude subscription). The report goes to Slack and, with the
full transcript, to the UI. **Nothing in the cluster is changed** in response
to an alert yet.

To stop runs without losing incidents, set `AGENT_ENABLED` to `"false"` in
`apps/alert-agent/deployment.yaml`.

## Agent runs

1. A new firing incident queues a run. Repeat deliveries for the same
   incident do not.
2. The controller starts **one run at a time**, at most `RUN_MAX_PER_HOUR`
   (6) per hour. A queued run whose incident resolves before it starts is
   skipped. Every run spends the subscription's usage.
3. Each run is a Job, `alert-agent-run-<id>`, with a per-run Secret holding a
   random bearer token and a GitHub token **narrowed to `contents:read` on this
   repo**. The Job owns the Secret, and both are deleted a day after it ends.
4. The runner clones this repo and runs `claude -p` in it. It streams every
   line of the transcript to the controller on port `8082` and reports the
   result. The token is revoked when the run ends.
5. A runner that dies without reporting is marked failed. That covers a
   deadline (`RUN_TIMEOUT`, 20m), a crash, or a Job that disappears.

### What bounds the agent

* **RBAC.** Claude's `kubectl` runs as `alert-agent-runner`: the built-in
  `view` role plus read on nodes, PVs, metrics and this cluster's CRDs. It can
  write nothing and **cannot read Secrets** anywhere.
* **Tool allowlist.** It runs in `dontAsk` mode, which denies anything not
  listed: read-only `kubectl` and `flux` subcommands, `curl` to the in-cluster
  Prometheus and Loki only, `git log/show/diff`, `scripts/render.sh` and text
  utilities. Edits, writes, web fetch and web search are denied.
* **Environment.** `claude` starts with an allowlisted environment, so the run
  token and GitHub token never reach it. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`
  also strips its own OAuth token from the commands it runs.
* **Prompt.** Alert text and logs are framed as untrusted data. The report
  classifies the fix as *autonomous*, *pr* or *human* for the phases that act
  on it.

## How alerts arrive

The `alert-agent` route is the last one in the Alertmanager config, after ntfy
and Slack, so the agent sees exactly what the humans saw and can never delay or
swallow a page. It groups by `alertname` and `namespace`, so one group is one
incident. Alerts from the `alert-agent` namespace are excluded, so the agent
never triages itself.

The receiver is index 4 in the `receivers` list. Indexes 1–3 are addressed by
position from `valuesFrom` in `infrastructure/prometheus/helm.yaml`, so new
receivers must be appended, never inserted.

## Incidents

* Each webhook delivery is stored verbatim in `webhook_deliveries` before
  anything is derived from it. That table is the first link in the audit trail.
* A firing group opens one incident, and repeat deliveries fold into it. A
  resolve closes it. The same group firing again opens a **new** incident.
* A resolve that matches no firing incident (for example, an alert that began
  before the agent existed) is recorded with no incident attached.
* If the database is down, the webhook answers 500 and Alertmanager retries.

## Architecture

* **Ports.** `8080` serves the UI, `/healthz`, `/readyz` and `/metrics`.
  `8081` serves only `POST /webhook/alertmanager`. The `alert-agent`
  NetworkPolicy admits Alertmanager's pods to `8081` and nothing else, because
  a delivery starts an agent run.
* **Migrations run in an init container** — the same image with `migrate`.
* **Database credentials** come from the operator-generated
  `alert-agent-database-app` Secret. Nobody chose that password.
* **Three ports.** Besides `8080` and `8081`, port `8082` serves the runner
  API to runner pods only.
* **`secrets.sops.yaml`** holds the Claude subscription token (mounted by
  runner Jobs) and the GitHub App credentials (mounted only by the
  controller, which mints narrowed tokens from them).
  `notify-secrets.sops.yaml` holds the Slack webhook for reports.
* **Runner image.** Runners use the controller pod's own image, which the
  controller looks up at startup. One Renovate bump moves both.
* **Backups** run nightly at 02:15 UTC to R2, with continuous WAL archiving.
  See [Postgres Backups](../infrastructure/postgres-backups.md).

## Probes

* **Liveness** (`/healthz`) does not touch the database; a restart does not fix
  a database outage.
* **Readiness** (`/readyz`) does, which takes the pod out of the Service while
  leaving it running.

## Metrics

| Metric | Meaning |
|--------|---------|
| `alert_agent_webhooks_total{outcome}` | Deliveries by outcome: `ok`, `bad_request`, `error` |
| `alert_agent_incidents_total{event}` | Incidents `opened` and `resolved` |
| `alert_agent_runs_total{status}` | Runs `queued`, and finished `succeeded` or `failed` |
