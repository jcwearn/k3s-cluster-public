# Mazanoke

[Mazanoke](https://github.com/civilblur/mazanoke) is a **self-hosted image
optimizer / converter** that runs entirely inside your browser: no uploads, no
tracking, no external dependencies—everything happens locally, even offline.  :contentReference[oaicite:0]{index=0}

| Setting            | Value                              |
|--------------------|------------------------------------|
| **URL**            | `https://image.${DOMAIN}` *(example)* |
| **Image**          | `civilblur/mazanoke:1.1.4`        |
| **Storage**        | Ephemeral (no database required)   |
| **Ingress class**  | `nginx` (TLS via cert-manager)     |
| **Namespace**      | `mazanoke`                         |

## Why it matters

* **Privacy-first** - images never leave your device.  :contentReference[oaicite:1]{index=1}
* **Multiple formats** - convert JPG, PNG, WebP, HEIC, AVIF, GIF, SVG.
* **Works offline** - progressive-web-app cache lets you resize on the go.

---

## TODO — Future improvements

* [ ] Add a PVC if you want persistent *default settings* or thumbnails
  (app is stateless by default).
* [ ] Explore adding authentication headers if you expose it publicly.
* [ ] Create a ServiceMonitor to scrape basic uptime metrics.

---

> Upload, compress, convert—**locally**.  No cloud, no problem! 🌩️