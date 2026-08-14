# ZeroClaw

ZeroClaw is a lightweight AI personal assistant daemon (~8.8 MB Rust binary) that connects messaging platforms to LLM providers with dynamic model routing.

## Overview

| | |
|---|---|
| **Namespace** | `zeroclaw` |
| **URL** | [zeroclaw.${DOMAIN}](https://zeroclaw.${DOMAIN}) |
| **Image** | `ghcr.io/zeroclaw-labs/zeroclaw` |
| **Port** | `42617` |
| **Storage** | 5 Gi NFS PVC at `/zeroclaw-data` |

## Configuration

ZeroClaw is configured via `/etc/zeroclaw/config.toml` (mounted from a ConfigMap). Secrets are injected as environment variables from a SOPS-encrypted Secret.

### Model Routing

| Hint | Provider | Model |
|------|----------|-------|
| `fast` | Gemini | `gemini-2.5-flash-lite` |
| `reasoning` | Gemini | `gemini-2.5-pro` |

Query classification automatically routes requests containing `analyze`, `explain`, `compare`, `debug`, or `write code` to the `reasoning` model; all others go to `fast`.

### Channels

- **Telegram** — bot token injected via `TELEGRAM_BOT_TOKEN` env var

### Secrets

| Key | Description |
|-----|-------------|
| `API_KEY` | Gemini API key (free tier) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token from BotFather |

## Files

```
apps/zeroclaw/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── httproute.yaml
├── pvc.yaml
├── secrets.sops.yaml
├── data/
│   └── config.toml
└── kustomization.yaml
```
