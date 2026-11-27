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

Phase 6 (self-monitoring) is live: every new incident gets a **diagnosis** by
Claude (Opus, on the Claude subscription). The report goes to Slack and, with
the full transcript, to the UI. When the fix is a manifest change, the agent
can also **propose a pull request** against this repo for a human to review,
and you can [chat with it](#chat) about that PR from the incident page. When
a small reversible action fixes it (delete a pod, restart a rollout, re-run a
CronJob, ask Flux to reconcile), the agent may **take one action** itself, or
**ask you to approve** it; see [Actions and approvals](#actions-and-approvals).
The agent cannot merge. It watches itself too: see [Runbook](#runbook) for
its alerts.

To stop runs without losing incidents, set `AGENT_ENABLED` to `"false"` in
`apps/alert-agent/deployment.yaml`. To keep diagnoses but stop PRs, set
`PR_ENABLED` to `"false"`. To stop autonomous actions at once, use the
**Pause** switch on the UI's home page; to turn actions and approvals off
entirely, set `ACTIONS_ENABLED` to `"false"`.

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
6. A run that fails because Claude **refused the token** or the
   **subscription's usage limit** is reached is **deferred**, not lost. Its
   incidents get a new run, held until a retry time (30m for the token, 1h
   for the limit). Nothing starts until then, chat turns included, and ntfy
   and Slack get one notice. The next successful run clears the block. A chat
   turn that hits it is answered with the reason instead.

### What bounds the agent

* **RBAC.** Claude's `kubectl` runs as `alert-agent-runner`: the built-in
  `view` role plus read on nodes, PVs, metrics and this cluster's CRDs. It can
  write nothing and **cannot read Secrets** anywhere. Cluster actions are made
  by the controller as a third identity, `alert-agent-actor`, which Claude
  never holds (see [Actions and approvals](#actions-and-approvals)).
* **No shell.** The agent's cluster tools are read-only MCP tools served by
  `alert-agent mcp` inside the runner pod: `kube_get` (any resource, CRDs
  included; Secrets refused), `kube_events`, `kube_logs`, Prometheus instant
  and range queries, Loki, and `git_log`/`git_show` on the checkout.
  `Read`/`Grep`/`Glob` are confined to the checkout. Bash, edits, web fetch and
  web search are denied, and `dontAsk` mode refuses anything else. `claude`
  also runs with `--restricted`, which removes the code-running tools,
  confines every file tool to the checkout and ignores settings files in the
  checkout, underneath those rules.
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

## Actions and approvals

An alert run may take **one** reversible action on the cluster, through four
controller tools:

| Tool | What it does | Refused when |
|---|---|---|
| `delete_pod` | Deletes one pod so its controller replaces it (a fresh emptyDir, a new process) | the pod has no ReplicaSet, StatefulSet, DaemonSet or Job owner: bare pods, CNPG instances and other operator-managed pods |
| `rollout_restart` | Sets the pod template's `restartedAt` annotation on a Deployment, StatefulSet or DaemonSet | |
| `rerun_cronjob` | Creates a Job from a CronJob's template, owned by the CronJob, named `<cronjob>-medic-<incident>` | one of its Jobs is still running, or it was already re-run for this incident |
| `flux_reconcile` | Sets `reconcile.fluxcd.io/requestedAt` on a Kustomization, HelmRelease or source | the object is suspended |

**Who acts.** The controller performs the call by impersonating the
`alert-agent-actor` ServiceAccount (`apps/alert-agent/rbac.yaml`); no pod runs
as it, and the controller's own identity can only impersonate it. The API
server's audit log names both. Where the actor may act is decided by
RoleBindings, namespace by namespace:

* **Autonomous:** the apps namespaces listed in `ACTION_AUTONOMOUS_NAMESPACES`.
* **Approval-only:** `ansible` (its Jobs run playbooks against the hosts) and
  alloy, loki, cert-manager, external-dns, tailscale, descheduler, reloader,
  csi-driver-nfs and envoy-gateway-system. A workload action there needs an
  approval; `flux_reconcile` does not.
* **Never:** everything else, including kube-system, the Flux controllers,
  `alert-agent`, `cnpg-system` and `prometheus` (the agent's own input:
  restarting it would hide alerts, not fix them). In `flux-system` the actor
  may only patch Flux objects.

RBAC cannot limit a patch to one annotation, so a ValidatingAdmissionPolicy
(`actor-policy.yaml`), matched on the actor's username, allows only the change
each tool makes: the `restartedAt` annotation on workloads, `requestedAt` on
Flux objects, deletes of controller-owned pods, and Jobs owned by a CronJob.

**Before it acts,** the controller checks the request with a server-side dry
run as the actor (RBAC, existence, the admission policy), then the
guardrails, in the same transaction that records the action:

1. The namespace's tier (above).
2. The **pause switch** on the home page.
3. **One action per incident**, merged incidents included.
4. A **cooldown** (`ACTION_COOLDOWN`, 6h): no autonomous action on a workload,
   or for an alert in a namespace, that had any action within it. An alert that
   fires again opens a new incident, so this is what turns a recurrence into an
   escalation instead of a retry.
5. An **hourly cap** (`ACTION_MAX_PER_HOUR`, 3).

Every call is written to the incident's **Activity** before it runs, marked
*autonomous* or *approved*, with the pod or object it touched, its workload,
the agent's reason, and afterwards the exact API call and its outcome (for a
delete, the pod's UID). Refusals are recorded too. The run's Slack diagnosis
lists them from the same record, and each run sees the actions taken in its
namespace or for its alert within the cooldown.

**Approvals.** When the guardrails hold an action back, the agent can call
`request_approval` with the same arguments and its reasoning. The controller
dry-runs it, records it, and notifies ntfy (`medic`) and Slack. The request
shows on the home page under **Awaiting approval**, on the incident page, and
in the incident's chat thread, with **Approve** and **Reject**. Approving runs
the action at once as the actor, skipping the guardrails (a human decided)
but not RBAC or the admission policy; a decision is recorded once, so a
second click does nothing. A request expires after `APPROVAL_TTL` (2h) or when
its incident resolves; a newer request for the same incident replaces it.
Chat turns on an incident can ask for approval but never act.

**Pause.** The home page's switch stops autonomous actions immediately; a
banner on every page says so. Runs still diagnose and may ask for approval.


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

### The incident list

The home page lists incidents 50 **families** at a time. A family is an
incident plus the incidents merged into it, and it never splits across pages.
"Older" and "Newer" page by the family's first incident: when it opened, then
its number. Every row shows the incident number (`#N`). **Awaiting approval**
and **Awaiting review** stay above the list and are never filtered.

The filters are a plain form, so a filtered view is a link you can share:

| Parameter | Meaning |
|---|---|
| `range` | `24h`, `7d` or `30d`: opened within that window |
| `from`, `to` | Dates (`2026-11-01`) in the controller's time zone (`TZ`). `to` includes its whole day. Either one overrides `range`. |
| `status` | `firing` or `resolved` |
| `ns`, `sev` | Namespace and severity, exact. The menus list every value seen. |
| `q` | Alert name contains this text, case-insensitive |
| `before`, `after` | The pager's position. Set by the Older and Newer links. |

A filter matches a family **as a whole**, and the whole family is shown:

- `status` is the family's status, the same one the row's badge shows: firing
  while any member fires.
- `ns`, `sev` and `q` match when the first incident or any merged incident
  matches all of them. A books incident with a merged gateway symptom
  appears under `ns=gateway`.
- The dates apply to the family's first incident.

An invalid value is ignored, and the page names it. For example,
`/?status=firing&ns=books&range=7d` shows books families with anything still
firing, opened in the last week.

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
| `alert_agent_actions_total{tool,mode,outcome}` | Cluster actions by tool, `autonomous` or `approved`, and `succeeded`, `rejected` or `failed` |
| `alert_agent_approvals_total{event}` | Approval requests `requested`, `approved`, `rejected`, `expired`, `superseded` |
| `alert_agent_run_failures_total{reason}` | Failed runs: `auth` and `usage_limit` (deferred), `other` |
| `alert_agent_claude_blocked{reason}` | 1 while Claude refuses every run, by `auth` or `usage_limit` |
| `alert_agent_runs_queued{kind}` | Runs waiting, `diagnose` or `chat`, held and deferred ones included |
| `alert_agent_oldest_queued_run_age_seconds` | Age of the oldest waiting run; 0 when none |
| `alert_agent_claude_token_created_timestamp_seconds` | The token Secret's `alert-agent/token-created` date; 0 if missing |

## Runbook

Rules in the `alert-agent` group of `infrastructure/prometheus/helm.yaml`.
They carry `namespace: alert-agent`, so they reach ntfy and Slack but never
the agent itself. Each alert links here.

### Pausing the agent

| To stop | Do |
|---------|----|
| Autonomous actions, now | **Pause** on the UI's home page (approvals still work) |
| All actions and approvals | `ACTIONS_ENABLED: "false"` in `apps/alert-agent/deployment.yaml` |
| PRs | `PR_ENABLED: "false"` |
| Every run (incidents are still recorded) | `AGENT_ENABLED: "false"` |
| Even recording | Remove the `alert-agent` route from Alertmanager in `infrastructure/prometheus/helm.yaml` |

Each file change is a commit and a merge; Flux applies it within 10 minutes,
or run `flux reconcile kustomization apps --with-source`.

### Token rotation

The runners use a one-year token from `claude setup-token`. The
`AlertAgentClaudeTokenExpiring` alert fires 30 days before it runs out.

1. On the Mac, run `claude setup-token` and copy the token it prints.
2. `sops apps/alert-agent/secrets.sops.yaml`. In the editor, replace
   `CLAUDE_CODE_OAUTH_TOKEN` **and** set the `alert-agent/token-created`
   annotation to today's date (`YYYY-MM-DD`). Never create or copy this file
   any other way (see CLAUDE.md on SOPS).
3. Commit, open a PR, merge.

Runner Jobs read the Secret when they start, so the next run uses the new
token; the controller rereads the date within 10 minutes. After an
`AlertAgentClaudeAuthFailing`, the block lifts at its retry time (up to 30
minutes) and the deferred runs go then.

### AlertAgentDown

Prometheus cannot scrape the controller. Alerts still reach ntfy and Slack;
nothing records them. Check `kubectl -n alert-agent get pods` and the pod's
events. The controller waits for its database, so a down `alert-agent-database`
keeps it from starting.

### AlertAgentWebhookErrors

The controller could not store Alertmanager deliveries, almost always the
database (`kubectl -n alert-agent get cluster alert-agent-database`).
Alertmanager retries, so incidents arrive late rather than never.

### AlertAgentRunsFailing

Two or more runs failed in an hour for a reason other than the token or the
limit: a timeout, a runner crash, a GitHub token error. The run page in the UI
shows the error and the transcript. `kubectl -n alert-agent logs deploy/alert-agent`
logs every `run failed` with its reason.

### AlertAgentClaudeAuthFailing

Claude rejects the token: it expired, or it was revoked. Runs are deferred, not
lost. Rotate it ([Token rotation](#token-rotation)).

### AlertAgentUsageLimited

Runs have been deferred for 3 hours at the subscription's limit. Interactive
Claude sessions draw on the same limit. Nothing is lost: deferred runs retry
hourly, and a run whose alerts resolved meanwhile is skipped. To save the
limit, pause runs with `AGENT_ENABLED: "false"`.

### AlertAgentQueueStuck

A run has waited over an hour with no block to explain it. The hourly cap
drains a queue within the hour, so the dispatcher has stopped: look for
`dispatch` errors in the controller log, and for a run stuck `running` whose
Job is gone (it is failed after a minute). A restart of the controller is
safe.

### AlertAgentActionsFailing

An action passed the guardrails and the dry run, then failed against the API
(a race with another change, or an API error). The incident's Activity has the
error. The guardrails count it, so the agent will not retry it within the
cooldown.

### AlertAgentGuardrailsRefusing

Three or more actions refused in an hour: the agent is retrying something the
cooldown or the hourly cap holds back. Read the refused rows in the
incidents' Activity; if the agent is wrong, **Pause** it.

### AlertAgentApprovalExpired

The agent asked to run an action and nobody answered within `APPROVAL_TTL`
(2h). If the incident still fires, act on it yourself or ask the agent again
in its chat.
