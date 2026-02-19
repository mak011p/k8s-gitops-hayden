# Odoo Development — Living Guide

**Keep this file as concise as possible.**

---

## Repository Structure

| Component | Path | Purpose |
|-----------|------|---------|
| Super repo | `~/Sites/odoo-development` | Builds the container image; commits reference submodule SHAs |
| Custom addons (submodule) | `~/Sites/odoo-development/addons/custom` | All custom/modified Odoo modules |
| Container image | `ghcr.io/hayden-agencies/odoo` | Built from super repo; tag format `18.0.YYYYMMDD.HHMM-<short-sha>` |

## Checking Recent Changes

### Custom addons (what changed)
```bash
cd ~/Sites/odoo-development/addons/custom && git log --oneline -10
```

### Super repo (which builds include what)
```bash
cd ~/Sites/odoo-development && git log --oneline -10
```
Super repo commits reference submodule SHA ranges, e.g.:
`db7d306 addons/custom: 2cf8d75 → ea5091c (duplicate receive orders guard)`

### Mapping image tag to commits
The image tag's short SHA (e.g. `db7d306` in `18.0.20260212.0240-db7d306`) is the **super repo** commit. To find the custom addons SHA it includes:
```bash
cd ~/Sites/odoo-development && git log --oneline -1 db7d306
# Shows the submodule range, e.g. "addons/custom: 2cf8d75 → ea5091c"
```

### Published images
```bash
gh api orgs/hayden-agencies/packages/container/odoo/versions \
  -q '.[0:5] | .[] | "\(.metadata.container.tags // ["untagged"] | join(",")) \(.updated_at)"'
```

## Staging vs Production

| Environment | Namespace | Image source |
|-------------|-----------|-------------|
| Staging | `business-system-staging` | Renovate auto-updates (separate PR) |
| Production | `business-system` | Renovate auto-updates (separate PR) |

Check which image a pod is running:
```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<name> \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Init Container: Auto Module Upgrade

Staging uses `click-odoo-update` as an init container — modules are automatically upgraded on each deploy. No manual `odoo -u` needed after image change.
