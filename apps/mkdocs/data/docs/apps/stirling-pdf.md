# Stirling PDF

[Stirling PDF](https://github.com/Stirling-Tools/Stirling-PDF) is a **privacy-first, self-hosted PDF toolbox**: merge, split, convert, rotate, compress, and edit PDFs directly in your browser—no uploads to third-party sites. 

| Setting / Resource | Value |
|--------------------|-------|
| **URL**            | `https://pdf.${DOMAIN}` |
| **Internal svc**   | `${LAN_PREFIX}.16:8080` |
| **Chart**          | *official* Helm chart `stirling-pdf` `1.9.1` |
| **Ingress class**  | `nginx` (TLS via cert-manager) |
| **Namespace**      | `stirling-pdf` |

## Why it matters

* **All-in-one Swiss-Army-knife** for PDFs — merge, split, convert, rotate, compress, watermark, OCR, and more.
* **100% local processing** — documents never leave your network.
* **API + UI** — scriptable endpoints for automations (Paperless-ngx, n8n, etc.).
* **Open-source & free** — replaces costly Acrobat or web SaaS tools.