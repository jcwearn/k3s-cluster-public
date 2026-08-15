# hivemind

[hivemind](https://github.com/jcwearn/hivemind) is a Jackbox-style party game.
One screen goes on a television, everybody else joins from their phone by
scanning a QR code, and **every player steers the same snake at once** — each
tick the server tallies the room's votes and the plurality direction wins.

Written in Go with htmx and server-sent events. No database, no JavaScript
framework, one static binary.

| Setting / Resource | Value |
|--------------------|-------|
| **URL**            | `https://hivemind.${DOMAIN}` |
| **Image**          | `ghcr.io/jcwearn/hivemind` |
| **Replicas**       | 1 (**required** — see below) |
| **Namespace**      | `hivemind` |

### Manifests

* **Deployment** — distroless static image (~8 MB), non-root, read-only root
  filesystem, `strategy: Recreate`.
* **Service** — ClusterIP; reached only through the shared Envoy Gateway.
* **HTTPRoute** — `hivemind.${DOMAIN}` via `main-gateway` (wildcard TLS).
* **BackendTrafficPolicy** — extends Envoy's timeouts to an hour. Required;
  see below.

### Why exactly one replica

Every room lives in the pod's memory. There is no database and nothing is
persisted — rooms are garbage-collected ten minutes after the last player
leaves.

Two replicas would therefore be two disjoint sets of rooms, with the Service
deciding at random which one a given phone reaches. A host would read a code off
the television that half the room could not join. `strategy: Recreate` exists
for the same reason: a rolling update briefly runs both pods at once, which is
exactly that failure for the length of the rollout.

The cost is a few seconds of downtime on deploy, and any round in progress is
lost. For a party game that is the cheaper trade.

### Why the BackendTrafficPolicy

State reaches every screen and phone over server-sent events — one HTTP response
held open for as long as somebody is playing. Envoy's default request timeout is
300 seconds, so without this every connection would be severed on a five-minute
cadence, mid-round.

The failure is worse than it sounds: the phones would quietly stop updating
while the television carried on, so it reads as a bug in the game rather than as
a proxy timeout.

The app sends a heartbeat comment every 20 seconds, so *idle* connections are
already safe. The policy is about the total lifetime of a stream.

### Notes

* `HIVEMIND_BASE_URL` must be the public hostname — it is what the join QR
  encodes. If it is wrong the television looks correct and every scan fails.
* `HIVEMIND_COOKIE_SECRET` is deliberately unset. It signs the cookie that lets
  a phone reclaim its seat, and the app generates an ephemeral one per process.
  A persistent secret would only matter if a seat could outlive the process, and
  it cannot — any restart that invalidates the cookie has already destroyed
  every room it could point at.
* Releases are label-driven semver from the app repo; Renovate bumps the pinned
  image digest here.
