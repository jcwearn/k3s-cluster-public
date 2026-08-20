"""Publish the endoflife.date release catalogue as Prometheus metrics.

This exporter deliberately knows nothing about what this cluster runs. The
running versions are already scraped -- node_os_info, kube_node_info and
pve_version_info between them cover all six machines -- so duplicating that
discovery here would mean a second source of truth and a set of credentials
this pod has no other reason to hold. The join happens in PromQL instead.
"""

import calendar
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://endoflife.date/api/v1/products/{product}/"

PRODUCTS = [p.strip() for p in os.environ.get("EOL_PRODUCTS", "").split(",") if p.strip()]
REFRESH_SECONDS = int(os.environ.get("EOL_REFRESH_SECONDS", "21600"))
LISTEN_PORT = int(os.environ.get("EOL_LISTEN_PORT", "9099"))
HTTP_TIMEOUT = int(os.environ.get("EOL_HTTP_TIMEOUT_SECONDS", "30"))

# product -> {"releases": list | None, "ok": 0 | 1, "ts": float}
# "releases" holds the last good catalogue and is never cleared by a failure:
# a transient endoflife.date outage must not blank the catalogue and make every
# release in the stack look unknown.
_snapshot = {}
_lock = threading.Lock()


def log(message):
    print(message, file=sys.stderr, flush=True)


def escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def to_epoch(day):
    # timegm rather than mktime: the dates are plain UTC calendar days and must
    # not be reinterpreted through whatever TZ the container happens to carry.
    return calendar.timegm(time.strptime(day, "%Y-%m-%d"))


def fetch(product):
    request = urllib.request.Request(
        API.format(product=product),
        headers={"Accept": "application/json", "User-Agent": "k3s-cluster-eol-exporter"},
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
        return json.load(response)["result"]["releases"]


def refresh_once():
    for product in PRODUCTS:
        try:
            releases = fetch(product)
        except Exception as exc:
            with _lock:
                entry = _snapshot.setdefault(product, {"releases": None, "ok": 0, "ts": 0.0})
                entry["ok"] = 0
            log("fetch failed for {0}: {1}".format(product, exc))
            continue
        with _lock:
            _snapshot[product] = {"releases": releases, "ok": 1, "ts": time.time()}
        log("fetched {0}: {1} cycles".format(product, len(releases)))


def refresh_loop():
    while True:
        time.sleep(REFRESH_SECONDS)
        refresh_once()


def ready():
    with _lock:
        return any(entry["releases"] is not None for entry in _snapshot.values())


def render():
    with _lock:
        snapshot = {product: dict(entry) for product, entry in _snapshot.items()}

    info, eol_at, is_eol, fetch_ok, fetch_ts = [], [], [], [], []

    for product in PRODUCTS:
        entry = snapshot.get(product, {"releases": None, "ok": 0, "ts": 0.0})
        label_product = escape(product)

        fetch_ok.append('eol_fetch_success{{product="{0}"}} {1}'.format(label_product, entry["ok"]))
        if entry["ts"]:
            fetch_ts.append(
                'eol_fetch_success_timestamp_seconds{{product="{0}"}} {1}'.format(
                    label_product, entry["ts"]
                )
            )

        for release in entry["releases"] or []:
            cycle = escape(release.get("name", ""))
            if not cycle:
                continue
            latest = (release.get("latest") or {}).get("name") or ""
            info.append(
                'eol_cycle_info{{product="{0}",cycle="{1}",label="{2}",latest="{3}"}} 1'.format(
                    label_product, cycle, escape(release.get("label") or ""), escape(latest)
                )
            )
            is_eol.append(
                'eol_cycle_is_eol{{product="{0}",cycle="{1}"}} {2}'.format(
                    label_product, cycle, 1 if release.get("isEol") else 0
                )
            )
            # Omitted, not zeroed, when upstream has announced no date -- which is
            # the case for proxmox-ve 9 right now. Absence keeps the "approaching"
            # alert from matching at all; any sentinel value would either be a lie
            # or fire forever.
            if release.get("eolFrom"):
                eol_at.append(
                    'eol_cycle_eol_timestamp_seconds{{product="{0}",cycle="{1}"}} {2}'.format(
                        label_product, cycle, to_epoch(release["eolFrom"])
                    )
                )

    families = [
        ("eol_cycle_info", "gauge", "Release cycle published by endoflife.date.", info),
        ("eol_cycle_eol_timestamp_seconds", "gauge",
         "End-of-life date for a release cycle. Absent when none is published.", eol_at),
        ("eol_cycle_is_eol", "gauge", "1 if the release cycle is past end of life.", is_eol),
        ("eol_fetch_success", "gauge", "1 if the last fetch for this product succeeded.", fetch_ok),
        ("eol_fetch_success_timestamp_seconds", "gauge",
         "Unix time of the last successful fetch for this product.", fetch_ts),
    ]

    out = []
    for name, kind, help_text, samples in families:
        if not samples:
            continue
        out.append("# HELP {0} {1}".format(name, help_text))
        out.append("# TYPE {0} {1}".format(name, kind))
        out.extend(samples)
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def respond(self, status, body, content_type="text/plain; charset=utf-8"):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/metrics"):
            self.respond(200, render())
        elif self.path.startswith("/-/ready"):
            if ready():
                self.respond(200, "ready\n")
            else:
                self.respond(503, "no catalogue yet\n")
        elif self.path.startswith("/-/healthy"):
            self.respond(200, "ok\n")
        else:
            self.respond(404, "not found\n")

    def log_message(self, *args):
        pass


def main():
    if not PRODUCTS:
        log("EOL_PRODUCTS is empty, nothing to poll")
        sys.exit(1)
    log("polling {0} every {1}s".format(",".join(PRODUCTS), REFRESH_SECONDS))
    refresh_once()
    threading.Thread(target=refresh_loop, daemon=True).start()
    ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
