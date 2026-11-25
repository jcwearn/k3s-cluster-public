# alert-agent

[alert-agent](https://github.com/jcwearn/alert-agent) is the cluster's **alert
triage agent**. Alertmanager sends it every alert that reached ntfy and Slack.
It records each one as an incident, and in later phases it runs Claude Code
headless against the incident: it fixes low-risk problems through a fixed set
of reversible actions and opens a pull request for anything larger.

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| **URL**            | `https://medic.${DOMAIN}`           |
| **Image**          | `ghcr.io/jcwearn/alert-agent`             |
| **Database**       | PostgreSQL 16 (CloudNative-PG)            |
| **Storage**        | None — all state is in Postgres           |
| **Ingress**        | Envoy Gateway HTTPRoute (UI only)         |
| **Namespace**      | `alert-agent`                             |

The design and phase plan are in `docs/plans/alert-agent/` in this repo. The UI
lives at `medic`, not `alert-agent`, so it doesn't share a browser-autocomplete
prefix with `alerts` (Alertmanager); the app, namespace and repo keep the
`alert-agent` name.

## Status

Phase 4 (chat in the UI and in PR comments) is live: every new incident gets a **diagnosis** by
Claude (Opus, on the Claude subscription). The report goes to Slack and, with
the full transcript, to the UI. When the fix is a manifest change, the agent
can also **propose a pull request** against this repo for a human to review,
and you can [chat with it](#chat) about that PR from the incident page.
**Nothing in the cluster is changed** in response to an alert, and the agent
cannot merge.

To stop runs without losing incidents, set `AGENT_ENABLED` to `"false"` in
`apps/alert-agent/deployment.yaml`. To keep diagnoses but stop PRs, set
`PR_ENABLED` to `"false"`.

## Agent runs

1. A new firing incident queues a run, **held** for `RUN_HOLD` (60s).
   Incidents that open in the same namespace during the hold join that run
   instead of getting their own (see [Consolidation](#consolidation)). Repeat
   deliveries for the same incident queue nothing.
2. The controller starts **one run at a time**, at most `RUN_MAX_PER_HOUR`
   (12) alert runs per hour; [chat](#chat) turns have their own budget. A
   queued run all of whose incidents resolve or are merged before it starts
   is skipped. Every run spends the subscription's usage.
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
* **No shell.** The agent's cluster tools are read-only MCP tools served by
  `alert-agent mcp` inside the runner pod: `kube_get` (any resource, CRDs
  included; Secrets refused), `kube_events`, `kube_logs`, Prometheus instant
  and range queries, Loki, and `git_log`/`git_show` on the checkout.
  `Read`/`Grep`/`Glob` are confined to the checkout. Bash, edits, web fetch and
  web search are denied, and `dontAsk` mode refuses anything else.
* **Environment.** `claude` starts with an allowlisted environment, so the run
  token and GitHub token never reach it. Its own OAuth token stays out of
  reach because there is no shell to run `env` and `Read` cannot leave the
  checkout to reach `/proc`. (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` would need
  bubblewrap, which the restricted runner pod cannot run.)
* **Prompt.** Alert text and logs are framed as untrusted data. The report
  classifies the fix as *autonomous*, *pr* or *human* for the phases that act
  on it.

## Pull requests

When the fix is a manifest change and the agent is reasonably confident, it
proposes a PR. **Git writes never come from Claude**:

1. The runner may edit its own checkout (`Edit(./**)`; edits to `scripts/`,
   `.githooks/`, `.github/`, `clusters/`, `apps/alert-agent/` and
   `*.sops.yaml` are denied). It takes the result from the read-only
   `git_diff` tool and passes it to `propose_pr(title, body, patch)`.
2. `propose_pr` is served by the **controller** over HTTP MCP on port `8082`,
   behind the run's bearer token. Only the controller holds the GitHub App
   key.
3. The controller clones `main`, applies the patch with `--3way`, and refuses
   anything that is not a regular file under `apps/` or `infrastructure/`:
   encrypted secrets, the agent's own `apps/alert-agent/`, symlinks, mode
   changes and binaries included.
4. It commits through this repo's own **`.githooks`**: every touched overlay
   must render, no plaintext Secret, no literal private address or tailnet
   name in the files or the message. `PUBLIC_GATE` fills the hooks'
   `.publicgate-local` with the real domain and tailnet (substituted by Flux).
5. The commit message is written by the controller; only the title comes
   from the agent, because commit messages are published on the public
   mirror. The PR body, which links the UI, is not (squash merges use the
   commit messages).
6. It pushes `agent/<incident-id>` and opens the PR. Only `agent/*` refs are
   ever pushed, nothing can merge, and each GitHub token is narrowed to one
   purpose.

Limits: one PR per incident and three `propose_pr` attempts per run. Every
call is written to the `actions` table before it runs, with its result after.

The controller polls open PRs every two minutes. The home page lists them
under **Awaiting review** with their CI state. Each PR gets **one review
notice** once its checks settle (or after 15 minutes), with the CI result: a
push on the ntfy `medic` topic and a message in Slack. If one channel fails,
the other still gets it. The Slack diagnosis links the PR too. ntfy carries
only review notices, so diagnoses never push.

Each run's Claude session file is stored (`run_sessions`), which is what lets
a [chat](#chat) resume the conversation on a pending PR.

## Chat

Every page has a **chat button** in the bottom-right corner. It opens a
window (a card on desktop, with a full-screen toggle; full screen on a phone)
for talking to the agent. A conversation is a **thread**:

* **An incident's thread.** There is one per incident; a merged incident's is
  its parent's. It continues **the agent's own Claude session** for the
  incident: the run that opened its PR, else its latest diagnosis. Ask why it
  made a change, ask for a different one, or, with no PR yet, ask for a fix
  (`propose_pr`, one PR per incident as for alert runs). PR comments join this
  same thread. An incident page's **Chat about this incident** button opens
  it.
* **General threads** are about the cluster as a whole ("how is the
  cluster?"). Each starts its own session, and its first message names it.

The window stays on its thread as you move around the UI, and every message
records the page it was sent from. The controller turns that path into a
description from its own records (an incident, a run, the home page) for
the agent. On an incident page while another thread is open, a bar offers to
switch to that incident's thread. The title opens a menu of recent threads
and **New conversation**. A thread is created by its first message, not by
opening the window.

What the agent can do depends on the thread:

| Thread | Read the cluster and incidents | Merge / link incidents | `propose_pr` | `update_pr` |
|---|---|---|---|---|
| General | yes | yes | no | no |
| Incident, no PR | yes | yes | yes | no |
| Incident, PR open | yes | yes | no | yes |
| Incident, PR merged or closed | yes | yes | no | no |

Merging and linking from chat work on any incident, since you are directing
it (the alert-run rules about confidence, namespace and window do not apply),
but only when you ask or agree. Each needs a reason and is audited as the
turn's run. `list_incidents` and `get_incident` let any thread read the
agent's incidents, not only the cluster.

1. Each message becomes a **chat turn**: a run of kind `chat`, labelled in the
   run list, with its own transcript. Chat turns go ahead of queued alert runs
   (a running one is never interrupted) and still run after the alert has
   resolved.
2. Messages sent while a turn is still waiting join it, so a few quick
   messages cost one turn. One waiting turn per thread.
3. The runner restores the thread's session file to
   `$HOME/.claude/projects/-work-repo/<session-id>.jsonl` and runs
   `claude -p --resume <session-id>`; a thread with no stored session yet
   starts it with `--session-id` (an incident's first turn gets the incident
   brief). The checkout is the PR branch `agent/<incident-id>` while the PR is
   open, else `main`.
4. A requested change to an open PR goes through
   **`update_pr(title, patch, pr_title)`**, served by the controller like
   `propose_pr`, with the same path checks, the same `.githooks` and a
   controller-written commit message. It is committed on the PR branch's head
   and the branch is only **fast-forwarded**: a commit anyone else pushed
   meanwhile is never overwritten (the turn is told the branch moved). The
   PR's file list is refreshed, so the overlap guard stays correct. When the
   change makes the PR's title wrong, the optional `pr_title` renames the PR
   once the commit lands, since a squash merge publishes the title. At most
   three calls per turn.
5. The turn's final message is the **reply**, with a line per commit it
   pushed (written by the controller from the audit trail, not by the agent).
   A running turn streams its steps into the window over SSE.

Limits: `CHAT_MAX_PER_THREAD_HOUR` (4) turns per thread per hour, and
`CHAT_MAX_PER_HOUR` (12) across all threads. A message over either cap is
refused at once ("Not processed … try again after HH:MM") rather than queued.
Chat turns do not count against `RUN_MAX_PER_HOUR`, and when that cap is full
the controller still starts them, so a long review never holds back an
alert's diagnosis (one run still goes at a time). Chat turns send no Slack or
ntfy notification.

UI changes are reviewed from screenshots: `alert-agent ui-preview` serves the
UI over made-up data on localhost, and `scripts/ui-screenshots.sh` in the
alert-agent repo captures every state with headless Chrome.

### PR comments

A comment on an open agent PR is a second way into its incident's thread.
There is no webhook (GitHub cannot reach the cluster), so the controller
polls every 30s (`COMMENT_POLL_INTERVAL`).

* **Who counts:** only people listed in `CHAT_ALLOWED_LOGINS` (`jcwearn`).
  The App's own comments, other bots and everyone else are ignored and
  counted in `alert_agent_pr_comments_total{outcome="ignored"}`, so the agent
  never answers itself.
* **What counts:** conversation comments, line comments and review bodies.
  Comments found in one pass, or while a turn waits, share that turn with any
  UI messages. Each comment is recorded once by its GitHub id, so a restart
  never answers twice; edits to older comments are ignored.
* **Acknowledge, then reply:** a queued comment gets 👀 (a review body cannot
  take a reaction). When the turn ends, the App posts the reply: in the thread
  when the turn's comments are all one line comment's thread, otherwise in
  the conversation, quoting each comment. The reply has the commit lines and a
  link to the turn's transcript. Turns with only UI messages stay in the UI.
* **Limits:** a comment over either turn limit gets a short "Not processed"
  reply instead of 👀.
* **Tokens:** `issues` and `pull_requests` read to poll, write to react and
  reply. The App has the Issues permission for this; conversation comments
  are issue endpoints.

Comments are not replayed to the public mirror; commit messages from
`update_pr` are, which is why the controller writes them.

## Consolidation

The agent's route groups by `alertname` and `namespace`, so one failing pod
can open several incidents at once (`KubernetesContainerOomKiller`,
`KubePodCrashLooping`, `KubePodNotReady`, ...). Three layers keep that to one
diagnosis and at most one PR:

1. **Hold.** A run waits `RUN_HOLD` before it can start, and incidents that
   open in the same namespace meanwhile join it. The run diagnoses its first
   (primary) incident and decides what each other member is. Members it
   neither merges nor hands off get a run of their own afterwards.
2. **Context and tools.** Every run sees the incidents still firing or opened
   within `RECENT_WINDOW` (30m), with the summary of their diagnosis, and the
   agent's open PRs with the files they change. Two controller tools act on
   that, each written to the audit trail before it runs:
    * `merge_incident(into_id, reason, confidence)` folds a **duplicate**
      (same failing object, same root cause) into the incident that owns the
      problem. The controller accepts it only with `confidence: high` and
      within **one namespace**; otherwise it tells the agent to link instead.
      A run that merges its own incident stops with a short `## Merged`
      report and posts nothing to Slack.
    * `link_incident(other_id, reason)` records a **related** incident (a
      shared node, an upstream dependency) that is a different problem.
3. **Backstop.** `propose_pr` refuses a merged incident (its parent owns the
   fix) and any change to a file an open agent PR already changes, naming
   that PR.

Alerts fired by the same cause but minutes apart (the OOM rule fires about
five minutes before the `Kube*` rules) are not caught by the hold; the later
run sees the earlier incident and its PR, and merges into it.

A merged incident keeps its own alerts, runs and history, and each alert still
resolves on its own. Merges are one level deep: merging into a merged incident
lands on its parent.

**From the UI**, each incident page has a **Related** card: *Merge into…*
and *Link to…* with a picker of the last day's incidents, *Unmerge* on a
merged incident, and *Unlink* on each link. A human may merge across
namespaces. The page's **Activity** table is the audit trail: every tool
call, merge, link, unmerge and unlink that names the incident, with who did
it (the agent's run, or a human in the UI) and the outcome. The home page
folds merged incidents under their parent and shows links as chips. Form
posts from another site are refused.

## How alerts arrive

The `alert-agent` route is the last one in the Alertmanager config, after ntfy
and Slack, so the agent sees exactly what the humans saw and can never delay or
swallow a page. It groups by `alertname` and `namespace`, so one group is one
incident; [Consolidation](#consolidation) folds incidents that are one problem. Alerts from the `alert-agent` namespace are excluded, so the agent
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
  `notify-secrets.sops.yaml` holds the Slack webhook for reports and review
  notices, and the ntfy token for review pushes (a copy of the one in `apps/ntfy`).
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
| `alert_agent_pull_requests_total{event}` | `propose_pr` outcomes (`opened`, `rejected`, `failed`), and PRs later `merged` or `closed` |
| `alert_agent_consolidations_total{kind,actor}` | Incident `merge`, `link`, `unmerge` and `unlink`, by `agent` or `ui` |
