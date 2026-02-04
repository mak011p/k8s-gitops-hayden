# KIND Local Development Secrets

This directory contains secrets for the KIND local development cluster.

## First-Time Setup

1. **Generate development Age key:**
   ```bash
   task kind:age-keygen
   ```

2. **Update .sops.yaml with your dev Age public key:**
   - Copy the public key from the output
   - Edit `.sops.yaml` and replace `DEV_AGE_PUBLIC_KEY_PLACEHOLDER` with your actual public key

3. **Create and encrypt secrets:**
   ```bash
   # Create cluster-secrets
   cp cluster-secrets.template.yaml cluster-secrets.enc.age.yaml
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys-dev.txt sops -e -i cluster-secrets.enc.age.yaml

   # Create sops-age secret (contains your dev Age private key)
   cp sops-age.template.yaml sops-age.enc.age.yaml
   # Edit sops-age.enc.age.yaml to add your Age private key from ~/.config/sops/age/keys-dev.txt
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys-dev.txt sops -e -i sops-age.enc.age.yaml
   ```

4. **Bootstrap the cluster:**
   ```bash
   task kind:setup
   ```

## Files

| File | Purpose | Encrypted |
|------|---------|-----------|
| `cluster-config.yaml` | Cluster variables (IPs, domains) | No |
| `cluster-secrets.enc.age.yaml` | Secret values for substitution | Yes (Age) |
| `sops-age.enc.age.yaml` | Age private key for Flux SOPS | Yes (Age) |

## Important Notes

- These secrets use a **separate development Age key**, NOT the production key
- You CANNOT decrypt production secrets with the dev key (by design)
- All domain/IP values are placeholders (localhost, 127.0.0.1)
- No real credentials should be stored here
