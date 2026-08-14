# Flux GitHub App Authentication

Flux authenticates to GitHub using a **GitHub App** instead of personal access tokens (PATs) or SSH deploy keys. The app's private key doesn't expire, so there are no periodic token rotations to manage — Flux automatically generates short-lived tokens from the private key.

## How It Works

1. A GitHub App (`flux-k3s-cluster`) is installed on the `jcwearn/k3s-cluster` repository with **Contents (read & write)** and **Metadata (read-only)** permissions.
2. The app's private key, App ID, and Installation ID are stored in the `flux-system` Secret in the `flux-system` namespace.
3. Flux's source-controller uses the `provider: github` field on the GitRepository resource to generate short-lived installation tokens from the private key on each reconciliation.

## Where the Secret Lives

```bash
kubectl -n flux-system get secret flux-system -o jsonpath='{.data}' | jq 'keys'
```

Expected keys: `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`.

## Rotating the Private Key

The private key does not expire, but you may want to rotate it if it's compromised.

1. Navigate to **GitHub → Settings → Developer settings → GitHub Apps → flux-k3s-cluster → General**.
2. Under **Private keys**, click **Generate a private key**. Save the new `.pem` file.
3. Revoke the old key in the same section.
4. Update the cluster secret:
   ```bash
   flux create secret githubapp flux-system \
     --namespace=flux-system \
     --app-id=<APP_ID> \
     --app-installation-id=<INSTALLATION_ID> \
     --app-private-key=./new-private-key.pem
   ```
5. Force reconciliation and verify:
   ```bash
   flux reconcile source git flux-system
   flux get sources git -A
   ```

All Git sources should report **Ready**.

## References

* [Flux GitHub App authentication docs](https://fluxcd.io/flux/components/source/gitrepositories/#github)
