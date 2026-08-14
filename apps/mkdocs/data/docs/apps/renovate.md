# Renovate (CronJob)

Keeps dependencies in *this* repo up-to-date by opening PRs automatically.

| Schedule | Image | Config |
|---|---|---|
| `0 */6 * * *` | `renovate/renovate:39.257.3` | `renovate.json` |

* Secrets for GitHub token are SOPS-encrypted.
* Output PRs trigger Flux workflows once merged.

> **TODO** – list any package rules or auto-merge configs you enable.