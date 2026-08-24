# Diagnosing a Blocked Domain

When an app or a site half-loads, hangs on a spinner, or works only with Tailscale
switched off, the cause is usually a DNS blocklist. This is the procedure for finding
*which* name is being blocked and unblocking it without loosening the filter.

## Know which resolver answered

There is no single query log any more. Since the tailnet's global nameserver moved off
the cluster, where a lookup is recorded depends on how the device was connected:

| Device is… | Resolver | Query log |
|---|---|---|
| On the tailnet (anywhere, including cellular) | NextDNS profile, over DoH | NextDNS console → **Logs** |
| On the LAN, Tailscale off, Default/Home Lab network | AdGuard Home (`${LAN_PREFIX}.2/.102/.103`) | AdGuard web UI |
| On Guest/IoT/NoT/Protect networks | UDM Pro → NextDNS over DoH | NextDNS, attributed to the gateway |
| Off-network entirely, Tailscale off | Carrier or café resolver | nowhere |

The first two rows are the ones that matter for "it works with Tailscale off": that
sentence means *AdGuard allows it and NextDNS blocks it*, which is a real and expected
gap. AdGuard runs `AdGuard DNS filter` + `HaGeZi Pro` + `HaGeZi TIF`; NextDNS runs
`HaGeZi Multi PRO` plus its own Security and Privacy toggles, and the two are equivalent
in intent but not domain-for-domain.

## Procedure

### 1. Prove it is DNS and not transport

In the Tailscale iOS app, stay **connected** but turn off **Use Tailscale DNS Settings**.

- Fixed → it is the resolver. Continue below, and turn the toggle back on afterwards.
- Still broken → it is exit-node routing or MTU, not DNS. Deselect the exit node and
  retest; the investigation moves to the Connector, not the blocklists.

### 2. Check the block page first

**Settings → Block page.** If it is on, turn it **off**, and retest before investigating
anything else.

This is a profile-wide setting and it is the highest-yield check in this document,
because it changes what *every* block does rather than what any one domain does:

| Block page | Blocked name resolves to | What the client does |
|---|---|---|
| **On** | a real NextDNS address serving an HTTP page | connects, starts TLS, gets a cert mismatch — slow failure, and some clients hang outright |
| **Off** | `0.0.0.0` and `::` | fails instantly; the app takes its error path |

So with it on, an app that merely *touches* a blocked domain can hang forever, even when
that domain is pure telemetry it does not need. The symptom looks exactly like a missing
dependency, which sends you hunting for a domain to allowlist when the real fix is one
toggle and no allowlist entry at all.

It also costs nothing to disable. A block page can only render for plain HTTP — NextDNS
cannot present a valid certificate for someone else's domain — so on a practically
all-HTTPS web it almost never displays as intended anyway. What it reliably produces is
certificate errors and hangs.

This is also why AdGuard never produced this class of failure: it answers blocked names
with `0.0.0.0`.

### 3. Read the NextDNS log

In the NextDNS console → **Logs**:

1. Pick the device from the dropdown. If devices are not named, the profile was added
   to Tailscale as a raw custom DoH URL instead of through Tailscale's built-in
   **NextDNS** integration — switch to the integration, which passes device metadata.
2. Turn on **Blocked Queries Only**.
3. Reproduce the failure (force-quit and reopen the app), then read the top of the log.
4. Open the `⋮` menu on each hit and note **which list or feature blocked it**. That
   attribution decides step 4: a blocklist hit and a Security-toggle hit are not fixed
   the same way.

### 4. Widen the search before concluding

Searching the obvious brand name misses most of an app's surface. A modern app talks to
its own domain, a shortened asset domain, a cloud backend, and a feature-flag service —
all different names. For the NYT apps that means searching `nytimes`, then `nyt`, then
`appspot`, then `launchdarkly`. Search each term separately rather than trusting one.

### 5. Query the profile directly

NextDNS's DoH endpoint serves the JSON DNS API, so the profile can be queried straight
from a laptop — no reproduction needed, and it does not matter what resolver the laptop
itself is using.

The profile ID is the DoH path: anyone holding it can query the profile, so it is a
secret. Keep it out of shell history and out of `ps` — do not type it on a command line
and do not `export` it. Store it in the login keychain once, prompted, and read it back:

```sh
# once. -w as the last option makes security(1) prompt, so the value never
# reaches a command line.
security add-generic-password -a "$USER" -s nextdns-profile -U -w

# thereafter
P=$(security find-generic-password -a "$USER" -s nextdns-profile -w)
```

Then, passing the URL to curl on stdin so the ID stays out of `ps` there too:

```sh
for d in als-svc.nytimes.com eg.nytimes.com a.et.nytimes.com purr.nytimes.com; do
  n=$(printf 'url = "https://dns.nextdns.io/%s/dns-query?name=%s&type=A"\nheader = "accept: application/dns-json"\nsilent\nmax-time = 5\n' "$P" "$d" \
      | curl -K - | grep -o '"data":"[0-9.]*"' | head -1 | cut -d'"' -f4)
  case "$n" in
    ""|0.0.0.0) echo "$d BLOCKED" ;;
    *)          echo "$d allowed ($n)" ;;
  esac
done
```

Keep one domain you know is fine and one you know is blocked in the list as controls, so
an empty answer means "blocked" and not "script broken".

**Where AdGuard fits, and where it does not.** AdGuard is *not* in the tailnet's chain —
tailnet DNS goes straight to NextDNS over DoH. It is only worth consulting for the
specific symptom "works with Tailscale off", where adding a
`dig +short @${LAN_PREFIX}.2 "$d"` column locates the NextDNS-only delta, because that
symptom *means* AdGuard allows what NextDNS blocks. Once the culprit is known its opinion
is irrelevant. In particular, when narrowing an over-broad allowlist, toggle each entry
off and query NextDNS alone: what a different blocklist thinks is not evidence about what
the app needs.

### 6. Allowlist narrowly, and only as a last resort

Reach this step only after step 2. An allowlist entry permanently loosens the filter for
every device on the tailnet (see below), so it is the expensive fix — spend it last.

**Settings → Allowlist**, one fully-qualified name per entry. Entries cover subdomains, so
allowlisting a bare apex unblocks everything under it: add
`securepubads.g.doubleclick.net`, never `doubleclick.net`.

Add the single most likely functional dependency first, retest, and stop as soon as the
app works — a domain being blocked at the right moment on the right device is not
evidence that the app needs it. Enable entries one at a time against a reproduction.

If an allowlist entry does not take effect, the block came from a **Security** or
**Privacy** toggle rather than a list. The attribution from step 3 names it; the only
fix is turning that one toggle off.

### 7. Decide whether AdGuard needs the same entry

Only if step 5 showed AdGuard blocking the domain too. AdGuard's config is in Git and
its web UI is ephemeral — the rendered config lands in an `emptyDir` and is re-derived
from the ConfigMap on every restart — so the entry must go in
`apps/adguardhome/data/AdGuardHome.yaml` under `user_rules`, in AdGuard syntax:

```yaml
user_rules:
  - "@@||securepubads.g.doubleclick.net^"
```

Most of the time this step is a no-op: if the symptom was "works with Tailscale off",
AdGuard was already allowing it.

## Worked example: Wordle in the NYT Games app

**Symptom.** The daily Wordle in the NYT Games iOS app showed an endless loading screen
unless Tailscale was disabled. Everything else on the phone was fine.

**Outcome first: the fix was turning the block page off. The allowlist is empty.** No
domain needed unblocking and the filter was never loosened. Everything below is the route
taken to that answer, and most of it was a detour.

**The false lead.** Filtering the log to the phone with **Blocked Queries Only** and
searching `nytimes` returned three names — `als-svc.nytimes.com`, `eg.nytimes.com`,
`a.et.nytimes.com` — and `als-svc` looked conclusive: an ad/audience config fetch, made at
launch, on the failing device. All three were innocent. The app works with all three
blocked.

**The domain that actually mattered** was `securepubads.g.doubleclick.net`, the Google
Publisher Tag host, which shares no substring with "nytimes" and never appeared in that
search. The post-game stats screen renders an ad slot and would not finish without it.

**But it did not need allowlisting either.** AdGuard blocks that same domain, returning
`0.0.0.0`, and the app had always worked fine on the LAN. Both resolvers blocked it; only
one caused a hang. The difference was the block page: NextDNS was answering with a real
address, so the app opened a connection, failed TLS, and waited. Turning the block page
off made the block fail instantly, the app took its error path, and the puzzle rendered
with an empty allowlist.

Three lessons, all about method:

- **Check the profile-wide settings before hunting a domain.** The block page changes what
  every block *does*. A whole evening of bisecting individual domains was spent on a
  symptom produced by one toggle. That is why it is now step 2.
- **Search by what the app loads, not by the brand in the URL bar.** The load-bearing name
  shared no substring with the product.
- **"Blocked at the right moment on the right device" is not causation.** Three domains fit
  that description perfectly and all three were innocent.

**Getting a reproduction.** The hard part was not diagnosis, it was that Wordle caches the
puzzle once loaded, so the failure could not be retried until the next day. What broke the
deadlock was noticing the *same* loading screen appears when returning to a completed
puzzle — an unlimited supply of cold loads, and the thing that made a one-at-a-time bisect
possible at all. Look for a second path to the same failure before resigning yourself to
one test per day.

**Why the cutover parity test did not catch it.** It could not have. The test compared
*which domains* each resolver blocks, and on that question the two agreed. The failure was
in *how* a block is answered, which no domain-by-domain comparison inspects.

## Current allowlist

**Empty, deliberately.** No entry has been needed. Both candidates that looked necessary
during the NYT Games investigation turned out not to be, once the block page was off.

Should an entry ever prove genuinely necessary, record it here — NextDNS has no Git
representation, so a rebuilt profile silently loses every entry and this table is the only
record.

| Domain | Added for | Reason |
|---|---|---|
| _(none)_ | | |

## There is no per-device profile

A recurring wish when one device needs a loose filter and the rest do not. It cannot be
done here, and the reason is structural:

- **Tailscale's global nameserver is tailnet-wide.** There is no per-device override in
  the admin console.
- **NextDNS has no per-device rules.** Allowlist and denylist are profile-scoped. A device
  picks a profile only by which DoH endpoint it queries, and Tailscale chooses that
  endpoint for every device at once.

The only per-device knob is client-side: turn off **Use Tailscale DNS Settings** on the
device and point it at a different profile through an OS-level DNS configuration. That
does select a profile per device, but it gives up MagicDNS — and since every
`*.${DOMAIN}` name is a public CNAME to the gateway's `.ts.net` name, the whole homelab
becomes unresolvable on that device. Rarely a good trade.

So an allowlist entry is tailnet-wide by construction. Keep entries host-specific rather
than apex-wide, and prefer a fix that needs no entry at all — turning the block page off,
or removing the dependency (a Games subscription removes the ad slot, and with it this
entry's reason to exist).

## Why none of this is in Git

The NextDNS profile, the Tailscale DNS page, and the UDM Pro's upstream are three web
consoles. Nothing here is reconcilable by Flux, and that is a deliberate consequence of
moving tailnet DNS off the cluster: the filter had to leave Git to stop depending on k3s.

The trade is that a rebuilt NextDNS profile silently loses every allowlist entry, with no
diff to catch it. Hence the table above.
