# SpotSwitcher Agent Instructions

- Always store SpotSwitcher secrets in Azure Key Vault:
  `/subscriptions/fb45451c-66aa-44de-9c41-35d17665ff46/resourceGroups/rg-shared-services/providers/Microsoft.KeyVault/vaults/tvr-shared-tv001-kv`.
- Do not store secret values in this repository, `.env` files, docs, plan files,
  tests, logs, or chat. Keep local files to placeholders and secret names only.
- The app runtime secret store is only a deployment target hydrated from Azure
  Key Vault.
- For CFES email notifications, do not create an app-side placeholder for
  `CFES_HMAC_SECRET`. The CFES maintainer creates the real per-client HMAC
  secret in Azure Key Vault, installs it on the shared Worker, and hydrates the
  app runtime secret target.
- If an unrelated required SpotSwitcher credential is missing, create an Azure
  Key Vault placeholder tagged `codexStatus=placeholder`, then tell Toby
  exactly which value to update manually.
