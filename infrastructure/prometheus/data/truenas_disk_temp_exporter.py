#!/usr/bin/env python3
"""Export TrueNAS disk temperatures to Prometheus.

Why this exists at all
----------------------
TrueNAS pushes its metrics to graphite-exporter, and every other metric from the
box arrives that way. Disk temperature does not. TrueNAS 25.10 moved it to a
python.d chart that collects every 300s, and netdata does not ship that chart
over the graphite exporter -- confirmed by watching a full collection cycle with
no sample arriving in any form, mapped or unmapped, while netdata itself held
fresh values the whole time.

So this reads the temperatures from the API instead, where they are correct,
current and version-stable. It is the one metric that dials TrueNAS rather than
waiting to be pushed. That is a deliberate exception to the design and not a
precedent: everything else stays push-only so it survives the cluster being
unreachable from the box.

Why it speaks WebSocket by hand
-------------------------------
TrueNAS's JSON-RPC 2.0 API is WebSocket-only -- there is no HTTP POST form of
it. The REST API would need no library at all, but TrueNAS 26 removes REST
entirely, and this repository has just finished getting off it; adding a new
consumer with a known expiry date would be moving backwards.

The alternative was a pip dependency, which would mean an initContainer and a
pod that cannot start when PyPI is unreachable. For a client that opens a
socket, sends three small frames and closes, the protocol below is smaller than
that machinery. It implements only what that needs: the RFC 6455 handshake,
masked text frames out, unmasked frames in with continuation and close handled.
No extensions, no compression, no ping initiation.
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.parse

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
TIMEOUT = int(os.environ.get("TIMEOUT_SECONDS", "30"))

_state_lock = threading.Lock()
_state: dict = {"temps": {}, "serials": {}, "ok": False, "last_success": 0.0, "error": ""}


# --------------------------------------------------------------------------
# Minimal RFC 6455 client. Text frames only.
# --------------------------------------------------------------------------
class WebSocket:
    def __init__(self, url: str, timeout: int = TIMEOUT):
        u = urllib.parse.urlparse(url)
        if u.scheme != "wss":
            # Not a style check: TrueNAS revokes an API key presented over an
            # unencrypted transport rather than rejecting it, so the failure
            # arrives later and looks nothing like this.
            raise ValueError(f"refusing non-wss URL: {url}")
        port = u.port or 443
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname)
        self._handshake(u)
        self._buf = b""
        self._id = 0

    def _handshake(self, u) -> None:
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path or "/"
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {u.hostname}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed during handshake")
            head += chunk
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise ConnectionError(f"websocket upgrade refused: {status}")
        # Anything after the header terminator is already frame data.
        self._pending = head.split(b"\r\n\r\n", 1)[1]

    def _recv_exact(self, n: int) -> bytes:
        while len(self._pending) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed mid-frame")
            self._pending += chunk
        out, self._pending = self._pending[:n], self._pending[n:]
        return out

    def send_text(self, payload: str) -> None:
        data = payload.encode()
        n = len(data)
        header = bytearray([0x81])  # FIN + text
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(header) + masked)

    def recv_text(self) -> str:
        """Read one complete message, reassembling continuation frames."""
        parts: list[bytes] = []
        while True:
            b0, b1 = self._recv_exact(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]
            if b1 & 0x80:  # server must not mask; tolerate it if it does
                mask = self._recv_exact(4)
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(self._recv_exact(length)))
            else:
                payload = self._recv_exact(length)
            if opcode == 0x8:
                raise ConnectionError("server closed the connection")
            if opcode == 0x9:  # ping -> pong, then keep reading
                self._send_control(0xA, payload)
                continue
            if opcode == 0xA:  # unsolicited pong
                continue
            parts.append(payload)
            if fin:
                return b"".join(parts).decode()

    def _send_control(self, opcode: int, payload: bytes = b"") -> None:
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked)

    def call(self, method: str, params=None):
        """One JSON-RPC request/response round trip."""
        self._id += 1
        self.send_text(json.dumps({
            "jsonrpc": "2.0", "id": self._id,
            "method": method, "params": params if params is not None else [],
        }))
        # The middleware interleaves notifications (collection updates, job
        # events) with responses, so read until the matching id comes back
        # rather than assuming the next frame is ours.
        while True:
            msg = json.loads(self.recv_text())
            if msg.get("id") != self._id:
                continue
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get("result")

    def close(self) -> None:
        try:
            self._send_control(0x8)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
def poll_once(url: str, username: str, api_key: str) -> tuple[dict, dict]:
    ws = WebSocket(url.rstrip("/").replace("https://", "wss://") + "/api/current")
    try:
        # auth.login_ex with API_KEY_PLAIN, not auth.login_with_api_key: TrueNAS
        # deprecates the latter in 26 and removes it in 27.
        r = ws.call("auth.login_ex", [{
            "mechanism": "API_KEY_PLAIN", "username": username, "api_key": api_key,
        }])
        if not isinstance(r, dict) or r.get("response_type") != "SUCCESS":
            rt = r.get("response_type") if isinstance(r, dict) else r
            # Name the account. login_ex validates the username and key as a
            # pair, so a username that does not own the key fails identically to
            # a bad key -- and the first time that happened the message said
            # only AUTH_ERR, which sent the search to the credential rather than
            # to the one line of config that was actually wrong.
            raise RuntimeError(f"authentication failed for {username!r}: {rt}")
        temps = ws.call("disk.temperatures") or {}
        # disk.temperatures is keyed by device name. The alerts print the serial,
        # because that is the only part a human can match to a drive in a bay.
        #
        # These two calls need different roles -- disk.temperatures wants
        # REPORTING_READ, disk.query wants DISK_READ -- so the serial lookup is
        # allowed to fail on its own. A key scoped to only the first still
        # produces temperatures, with an empty serial label, rather than
        # producing nothing. Losing a label is worth less than losing thermal
        # alerting on a NAS.
        try:
            disks = ws.call("disk.query", [[], {"select": ["name", "serial"]}]) or []
            serials = {d["name"]: (d.get("serial") or "") for d in disks}
        except Exception as exc:  # noqa: BLE001
            print(f"serial lookup unavailable ({type(exc).__name__}); "
                  f"exporting temperatures without serial labels", file=sys.stderr, flush=True)
            serials = {}
        return temps, serials
    finally:
        ws.close()


def render() -> str:
    with _state_lock:
        temps = dict(_state["temps"])
        serials = dict(_state["serials"])
        ok, last, err = _state["ok"], _state["last_success"], _state["error"]
    out = [
        "# HELP disk_temperature Disk temperature in celsius, read from the TrueNAS API.",
        "# TYPE disk_temperature gauge",
    ]
    for disk in sorted(temps):
        v = temps[disk]
        if v is None:
            continue
        serial = serials.get(disk, "")
        out.append(f'disk_temperature{{disk="{disk}",serial="{serial}"}} {v}')
    out += [
        "# HELP truenas_disk_temp_scrape_success Whether the last poll of the TrueNAS API succeeded.",
        "# TYPE truenas_disk_temp_scrape_success gauge",
        f"truenas_disk_temp_scrape_success {1 if ok else 0}",
        "# HELP truenas_disk_temp_last_success_timestamp_seconds Unix time of the last successful poll.",
        "# TYPE truenas_disk_temp_last_success_timestamp_seconds gauge",
        f"truenas_disk_temp_last_success_timestamp_seconds {last}",
    ]
    if err:
        out.append(f"# last error: {err[:200]}")
    return "\n".join(out) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.startswith("/metrics"):
            body = render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/-/ready"):
            # Ready only once real temperatures have been read, so a pod that has
            # never reached TrueNAS is never scraped as though its empty result
            # were the truth.
            with _state_lock:
                ready = bool(_state["temps"])
            self.send_response(200 if ready else 503)
            self.end_headers()
            self.wfile.write(b"ok\n" if ready else b"no data yet\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):  # keep the pod log to real events
        pass


def main() -> int:
    url = os.environ.get("TRUENAS_URL", "")
    username = os.environ.get("TRUENAS_USERNAME", "")
    api_key = os.environ.get("TRUENAS_API_KEY", "")
    for name, val in (("TRUENAS_URL", url), ("TRUENAS_USERNAME", username), ("TRUENAS_API_KEY", api_key)):
        if not val:
            sys.exit(f"{name} is not set")

    srv = http.server.ThreadingHTTPServer(("", LISTEN_PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"listening on :{LISTEN_PORT}, polling every {POLL_SECONDS}s", flush=True)

    while True:
        try:
            temps, serials = poll_once(url, username, api_key)
            with _state_lock:
                _state.update(temps=temps, serials=serials, ok=True,
                              last_success=time.time(), error="")
        except Exception as exc:  # noqa: BLE001
            # Keep the last good readings rather than dropping to zero: a failed
            # poll is a scrape problem, not a cold drive. truenas_disk_temp_
            # scrape_success is what says the readings are stale.
            with _state_lock:
                _state.update(ok=False, error=f"{type(exc).__name__}: {exc}")
            print(f"poll failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    raise SystemExit(main())
