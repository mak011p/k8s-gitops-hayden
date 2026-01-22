# Secrets Management & Key Rotation

This document provides guidance on managing and rotating secrets used in this cluster.

## Overview

Secrets are stored in multiple locations:

| Location | Purpose | Access Method |
|----------|---------|---------------|
| **1Password** | Primary secret store | External Secrets Operator |
| **GitHub Actions** | CI/CD workflows | Repository/Org secrets |
| **SOPS-encrypted files** | GitOps-managed secrets | Age + GCP KMS |

## Automated Rotation Script

The `hack/rotate-secrets.sh` script automates GCP service account key rotation:

```bash
# Rotate all GCP service account keys (auto-updates 1Password)
./hack/rotate-secrets.sh

# Rotate a specific key
./hack/rotate-secrets.sh velero

# List available service accounts
./hack/rotate-secrets.sh --list

# Manual mode (clipboard instead of 1Password CLI)
./hack/rotate-secrets.sh --manual
```

**Requirements:**
- `gcloud` CLI (authenticated)
- `op` CLI (1Password CLI) - or use `--manual` flag

---

## 1Password Secrets Inventory

All secrets are stored in the **Kubernetes** vault.

### GCP Service Account Keys

These are rotated automatically by `hack/rotate-secrets.sh`:

| 1Password Item | Field | GCP Service Account | Purpose |
|----------------|-------|---------------------|---------|
| `velero-gcs` | `credentials` | `velero@hayden-agencies-infra` | Velero cluster backups |
| `thanos-objstore` | `serviceAccount` | `thanos@hayden-agencies-infra` | Prometheus long-term storage |
| `odoo-objstore` | `serviceAccount` | `odoo-pg-backup@hayden-agencies-infra` | Odoo database backups |
| `chatwoot-objstore` | `serviceAccount` | `chatwoot-pg-backup@hayden-agencies-infra` | Chatwoot database backups |
| `nextcloud-objstore` | `serviceAccount` | `nextcloud-backup@hayden-agencies-infra` | Nextcloud data backups |
| `openebs-objstore` | `serviceAccount` | `openebs-backup@hayden-agencies-infra` | OpenEBS volume backups |
| `threecx-objstore` | `serviceAccount` | `threecx-backup@hayden-agencies-infra` | ThreeCX backups |

### HMAC Keys (S3-style)

Requires manual rotation via GCP Console:

| 1Password Item | Fields | Purpose |
|----------------|--------|---------|
| `magento2-objstore` | `accessKeyId`, `secretAccessKey` | Magento2 S3-compatible backup |

**Rotation steps:**
1. Go to https://console.cloud.google.com/storage/settings;tab=interoperability
2. Create new HMAC key for `magento2-pg-backup@hayden-agencies-infra.iam.gserviceaccount.com`
3. Update 1Password item with new `accessKeyId` and `secretAccessKey`
4. Delete old HMAC key

### Third-Party API Credentials

| 1Password Item | Fields | Purpose | Rotation URL |
|----------------|--------|---------|--------------|
| `cloudflare` | `CLOUDFLARE_API_TOKEN` | DNS management, CDN | https://dash.cloudflare.com/profile/api-tokens |
| `cloudflare` | `CLOUDFLARED_TUNNEL_CREDENTIALS` | Cloudflare Tunnel | https://one.dash.cloudflare.com → Tunnels |
| `dex` | `CLIENT_ID`, `CLIENT_SECRET`, `COOKIE_SECRET` | Google OAuth (Dex OIDC) | https://console.cloud.google.com/apis/credentials |
| `actions-runner` | `ACTIONS_RUNNER_PRIVATE_KEY` | GitHub Actions Runner | https://github.com/settings/apps |
| `ghcr-odoo-pull` | `GHCR_PAT` | Container registry auth | https://github.com/settings/tokens |
| `flux` | Various | FluxCD GitHub access | https://github.com/settings/tokens |

### External Secrets Operator

| 1Password Item | Purpose |
|----------------|---------|
| `1password` | 1Password Connect token (bootstraps ESO) |

---

## GitHub Actions Secrets

### mak011p/k8s-gitops-hayden

| Secret | Purpose | Rotation |
|--------|---------|----------|
| `GHCR_PAT` | Renovate reads GHCR image tags | GitHub PAT with `read:packages` |
| `BOT_APP_ID` | GitHub App for automated commits | GitHub App settings |
| `BOT_APP_PRIVATE_KEY` | GitHub App authentication | Generate new key in App settings |
| `BOT_USERNAME` | Bot display name | - |
| `BOT_USER_ID` | Bot user ID | - |

### mak011p/odoo-deployment-development

| Secret | Purpose | Rotation |
|--------|---------|----------|
| `GHCR_PAT` | Push images to GHCR | GitHub PAT with `write:packages` |
| `SUBMODULE_PAT` | Clone private submodules | GitHub PAT with `repo` scope |
| `BOT_APP_ID` | GitHub App | Same as above |
| `BOT_APP_PRIVATE_KEY` | GitHub App | Same as above |
| `BOT_USERNAME` | Bot display name | - |
| `BOT_USER_ID` | Bot user ID | - |

---

## GHCR Authentication

### Architecture

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────┐
│ mak011p/odoo-deployment-development │     │ mak011p/k8s-gitops-hayden       │
│                                     │     │                                 │
│ GHCR_PAT → Push images              │     │ GHCR_PAT → Renovate reads tags  │
└─────────────────────────────────────┘     └─────────────────────────────────┘
                │                                       │
                ▼                                       ▼
        ghcr.io/hayden-agencies/odoo          Renovate checks for updates
                ▲
                │
┌───────────────┴─────────────────────┐
│ Kubernetes Cluster                  │
│                                     │
│ 1Password (ghcr-odoo-pull)          │
│     ↓                               │
│ ExternalSecret → ghcr-pull          │
│     ↓                               │
│ Pod imagePullSecrets                │
└─────────────────────────────────────┘
```

### Rotation Procedure

1. **Create new GitHub PAT** at https://github.com/settings/tokens
   - Classic PAT with `write:packages` scope (includes read)

2. **Update GitHub Actions secrets:**
   ```bash
   gh secret set GHCR_PAT --repo mak011p/odoo-deployment-development
   gh secret set GHCR_PAT --repo mak011p/k8s-gitops-hayden
   ```

3. **Update 1Password:** Edit `ghcr-odoo-pull` → `GHCR_PAT` field

4. **Verify:**
   ```bash
   # Test push
   gh workflow run build-push.yaml --repo mak011p/odoo-deployment-development
   gh run watch --repo mak011p/odoo-deployment-development

   # Check cluster sync
   kubectl get externalsecret ghcr-pull -n business-system
   ```

---

## SOPS Encryption

All secrets use Age encryption. PGP has been phased out.

| Key Type | Identifier | Purpose |
|----------|------------|---------|
| Age | `age1ha5rkmrmdgd079xkvlp3svelhgd3wxm9l0v88es7hjp6ujcvnyjsxxrc7h` | Primary encryption |
| GCP KMS | `projects/hayden-agencies-infra/locations/global/keyRings/sops/cryptoKeys/sops-key` | Backup/bootstrap |

**Key locations:**
- Local: `~/.config/sops/age/keys.txt`
- Cluster: `kubernetes/clusters/cluster-00/secrets/sops-age.encrypted.yaml`

**Rotation:**
1. Generate new keypair: `age-keygen -o new-key.txt`
2. Update `.sops.yaml` with new public key
3. Re-encrypt all `.enc.age.yaml` files
4. Update cluster secret and local key file

---

## Quick Reference

### Check Secret Status

```bash
# GitHub Actions secrets
gh secret list --repo mak011p/k8s-gitops-hayden
gh secret list --repo mak011p/odoo-deployment-development

# Kubernetes ExternalSecrets
kubectl get externalsecret -A

# Specific secret sync status
kubectl get externalsecret ghcr-pull -n business-system
```

### Force ExternalSecret Refresh

```bash
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

### View GCP Service Account Keys

```bash
gcloud iam service-accounts keys list \
  --iam-account=velero@hayden-agencies-infra.iam.gserviceaccount.com
```

---

## Naming Conventions

| Pattern | Location | Example |
|---------|----------|---------|
| `SCREAMING_SNAKE_CASE` | GitHub Actions | `GHCR_PAT` |
| `kebab-case` | 1Password items | `ghcr-odoo-pull` |
| `kebab-case` | Kubernetes Secrets | `ghcr-pull` |
| `*.enc.age.yaml` | SOPS encrypted | `secret.enc.age.yaml` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Build fails at "Log in to Container Registry" | Invalid GHCR_PAT | Rotate token |
| ExternalSecret `SecretSyncedError` | 1Password item missing/wrong | Check 1Password |
| Pod `ImagePullBackOff` | Pull secret invalid | Check ExternalSecret status |
| Renovate can't check versions | GHCR_PAT expired | Rotate in k8s-gitops-hayden |
| `op` CLI auth fails | Session expired | Run `eval "$(op signin)"` |
