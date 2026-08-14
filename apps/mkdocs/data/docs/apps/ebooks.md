# Ebooks

A **self-hosted ebook management stack** combining Shelfmark for book
discovery/downloading and Calibre-Web for library management and reading.
All download traffic is routed through a Gluetun VPN sidecar.

| Component        | URL                          | LB IP             |
|------------------|------------------------------|--------------------|
| **Shelfmark**    | `https://shelfmark.${DOMAIN}`| `${LAN_PREFIX}.29`   |
| **Calibre-Web**  | `https://books.${DOMAIN}`    | `${LAN_PREFIX}.30`   |

**Namespace:** `ebooks`

---

## Architecture

```
┌─────────────────────────────────┐
│  Shelfmark Pod                  │
│  ┌───────────┐  ┌────────────┐  │
│  │ Shelfmark │  │  Gluetun   │  │
│  │  :8084    │  │ (VPN side- │  │
│  │           │  │  car)      │  │
│  └─────┬─────┘  └────────────┘  │
│        │                        │
│        ▼                        │
│   shelfmark-books PVC           │
│   (downloads)                   │
└────────┬────────────────────────┘
         │  shared volume
         ▼
┌─────────────────────────────────┐
│  Calibre-Web Pod                │
│  ┌─────────────┐ ┌───────────┐  │
│  │ Calibre-Web │ │ Auto-     │  │
│  │  :8083      │ │ Import    │  │
│  │             │ │ sidecar   │  │
│  └──────┬──────┘ └─────┬─────┘  │
│         │              │        │
│         ▼              ▼        │
│     calibre-library PVC         │
└─────────────────────────────────┘
```

---

## Shelfmark

[Shelfmark](https://github.com/calibrain/shelfmark) is an ebook search
and download tool.

| Setting   | Value                                 |
|-----------|---------------------------------------|
| **Image** | `ghcr.io/calibrain/shelfmark:1.0.4`  |
| **Port**  | `8084`                                |

* Mounts `calibre-web-config` read-only at `/auth` for auth sharing with
  Calibre-Web
* Downloads are saved to the `shelfmark-books` PVC at `/books`

---

## Calibre-Web

[Calibre-Web](https://github.com/janeczku/calibre-web) provides a web
interface for browsing, reading, and managing an ebook library.

| Setting   | Value                                          |
|-----------|------------------------------------------------|
| **Image** | `lscr.io/linuxserver/calibre-web:0.6.26-ls370` |
| **Port**  | `8083`                                          |

### Init Container

A Python init container creates an empty `metadata.db` (Calibre database
schema) if one does not already exist, so that Calibre-Web can start
cleanly on a fresh volume.

### Auto-Import Sidecar

A sidecar container (`lscr.io/linuxserver/calibre:v9.2.1-ls386`) watches
the `/downloads` directory (backed by `shelfmark-books` PVC) every **60
seconds** for new ebook files and automatically imports them into the
Calibre library using `calibredb add`.

Supported formats: epub, mobi, pdf, azw3, azw, cbz, cbr, fb2, djvu, lit,
prc, doc, docx, rtf, txt.

---

## Gluetun VPN Sidecar

[Gluetun](https://github.com/qdm12/gluetun) runs as a sidecar in the
Shelfmark pod, routing all download traffic through a VPN tunnel.

| Setting      | Value                     |
|--------------|---------------------------|
| **Image**    | `qmcgaw/gluetun:v3.41.1` |
| **Provider** | ProtonVPN                 |
| **Protocol** | WireGuard                 |
| **Exit**     | Netherlands               |

* Requires `NET_ADMIN` capability for tunnel creation
* VPN credentials are stored in a SOPS-encrypted secret
  (`gluetun-vpn-credentials`)

---

## Storage

| PVC                  | Size  | Used by                              |
|----------------------|-------|--------------------------------------|
| `shelfmark-config`   | 1Gi   | Shelfmark app config                 |
| `shelfmark-books`    | 20Gi  | Downloads (shared with auto-import)  |
| `calibre-library`    | 50Gi  | Calibre book library + metadata.db   |
| `calibre-web-config` | 1Gi   | Calibre-Web config (shared with Shelfmark for auth) |

All PVCs use `ReadWriteMany` access mode on `truenas-nfs-rwx` storage
class.

---

## Access

* **Shelfmark**: `https://shelfmark.${DOMAIN}` / Tailscale `shelfmark` / LB `${LAN_PREFIX}.29`
* **Calibre-Web**: `https://books.${DOMAIN}` / Tailscale `calibre-web` / LB `${LAN_PREFIX}.30`

---

## Flux Object Path

All manifests live in `./apps/ebooks/` and are reconciled via GitOps.
VPN credentials (`gluetun-secrets.sops.yaml`) are SOPS-encrypted.
