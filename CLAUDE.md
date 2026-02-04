# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Kubernetes GitOps repository for SME cluster managed with FluxCD and Talos Linux. The cluster aims to follow enterprise-grade security and observability practices, showcasing CNCF ecosystem tools.

## Architecture

- **Operating System**: Talos Linux (minimal, immutable Kubernetes OS)
- **GitOps**: FluxCD with Flux Operator for declarative cluster management
- **Container Runtime**: containerd
- **Networking**: Cilium CNI with Istio service mesh
- **Storage**: Rook-Ceph, OpenEBS, democratic-csi for container-attached storage, UNRAID (for less critical storage)
- **Monitoring**: Prometheus, Grafana, Loki, Jaeger, Thanos for observability
- **Security**: Kyverno, OPA Gatekeeper for policy management, Falco & Tetragon for runtime security
- **Load Balancing**: MetalLB for bare metal load balancing
- **Chaos Engineering**: Litmus for chaos testing

## Cluster Topology

- Cluster-00 runs 3 Talos control-plane nodes and 3 Talos worker nodes.
- Control planes are NVMe boot only; avoid scheduling storage workloads there.
- Rook Ceph OSDs should bind to worker NVMe by-id devices (update the filter to exact IDs when known).

## Directory Structure

```
├── kubernetes/                       # Kubernetes manifests and configurations
│   ├── apps/
│   │   ├── base/                     # Base application configurations (DRY principle)
│   │   │   └── [system-name]/        # e.g., observability, kube-system, home-system
│   │   │       ├── [app-name]/
│   │   │       │   ├── app/          # HelmRelease, OCIRepository, secrets, values
│   │   │       │   └── ks.yaml       # Flux Kustomization with dependencies
│   │   │       ├── namespace.yaml
│   │   │       └── kustomization.yaml
│   │   └── overlays/
│   │       ├── cluster-00/           # Upstream overlay (from xunholy/k8s-gitops)
│   │       └── cluster-00-local/     # Production overlay (extends cluster-00 with local additions)
│   ├── bootstrap/
│   │   └── helmfile.yaml             # Bootstrap Flux Operator and dependencies
│   ├── clusters/
│   │   └── cluster-00/
│   │       ├── flux-system/          # Flux Operator and FluxInstance configs
│   │       ├── secrets/              # Cluster secrets (SOPS encrypted)
│   │       └── ks.yaml               # Root Kustomization
│   ├── components/
│   │   └── common/alerts/            # Shared monitoring alerts
│   └── tenants/                      # Multi-tenant configurations
├── talos/                            # Talos Linux configuration files
│   ├── generated/                    # Generated Talos configs (encrypted)
│   ├── integrations/                 # Cilium, cert-approver integrations
│   └── patches/                      # iSCSI, metrics patches
├── terraform/                        # Infrastructure as Code
│   ├── cloudflare/                   # Cloudflare DNS/CDN configuration
│   └── gcp/                          # GCP KMS, Thanos storage, Velero backups
├── .taskfiles/                       # Task automation definitions
└── docs/                             # Documentation
```

### Overlay Strategy

This repo is forked from [xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops). Two overlays exist to cleanly separate upstream from local:

- **`cluster-00`**: Mirrors the upstream overlay. Kept close to upstream to minimize merge conflicts during syncs.
- **`cluster-00-local`**: Extends `cluster-00` (via `- ../cluster-00` base reference) and adds local resources (kagent, kmcp, n8n, velero, home-assistant, democratic-csi, odoo-staging, kyverno, etc.).

The root Flux Kustomization (`kubernetes/clusters/cluster-00/ks.yaml`) points to `cluster-00-local`, so **`cluster-00-local` is the active production overlay**.

## Common Commands

### Task Management (Primary Build System)
The repository uses [Task](https://taskfile.dev) for automation. All commands should be run via `task`:

```bash
# FluxCD Operations
task flux:bootstrap          # Bootstrap Flux Operator via Helmfile
task flux:secrets           # Install cluster secrets (SOPS decrypt + apply)
task fluxcd:bootstrap       # Alternative bootstrap path
task fluxcd:diff            # Preview FluxCD operator changes

# Talos Operations
task talos:config           # Decrypt and load talosconfig to ~/.talos/config

# Core Operations
task core:gpg               # Import SOPS keys (legacy)
task core:lint              # Run yamllint

# View available tasks
task --list
```

**Important Variables:**
- `CLUSTER`: cluster-00 (default cluster ID)
- `GITHUB_USER`: mak011p
- `GITHUB_REPO`: k8s-gitops-hayden
- `GITHUB_BRANCH`: master

### Pre-commit Hooks
The repository uses pre-commit for code quality:
```bash
pre-commit run --all-files   # Run all pre-commit hooks
```

Active hooks include:
- YAML/JSON/TOML validation
- yamllint (with `.yamllint.yaml` config)
- shellcheck for shell scripts
- Trailing whitespace and EOF fixes

### Secret Management
Secrets are managed via **1Password** (External Secrets Operator) and **SOPS** (Age encryption) for GitOps files.

```bash
# Edit SOPS-encrypted files (automatically decrypts/encrypts)
sops path/to/file.enc.age.yaml

# Encrypt new secrets
mv secret.yaml secret.enc.age.yaml && sops -e -i secret.enc.age.yaml
```

> **For detailed secrets inventory, rotation procedures, and troubleshooting, see [SECRETS.md](SECRETS.md)**

## Key Technologies & Patterns

### GitOps with FluxCD
This repository uses **Flux Operator** instead of traditional `flux bootstrap`:
- **FluxInstance CRDs**: Declaratively manage FluxCD components
- **OCIRepository**: Used for Helm charts instead of HelmRepository (e.g., `oci://ghcr.io/prometheus-community/charts`)
- **Kustomizations**: Define manifest application with SOPS decryption, post-build substitution, and dependency chains
- **HelmReleases**: Reference charts via `chartRef` pointing to OCIRepository
- **Root Kustomization**: Located at `kubernetes/clusters/cluster-00/ks.yaml`

### Application Deployment Pattern
Each application follows this structure:
1. **Base configuration** in `kubernetes/apps/base/[system-name]/[app-name]/`:
   - `app/helmrelease.yaml`: Helm release definition
   - `app/ocirepository.yaml`: Chart source
   - `app/secret.enc.yaml`: Encrypted secrets
   - `app/values.yaml`: Helm values
   - `ks.yaml`: Flux Kustomization with `dependsOn`, SOPS settings, substitutions

2. **Cluster overlays** in `kubernetes/apps/overlays/cluster-00/`: Cluster-specific customizations using Kustomize patches

3. **System categories**: Apps organized into logical systems:
   - `kube-system`: Core Kubernetes (Cilium, metrics-server, reflector)
   - `network-system`: Networking (cert-manager, external-dns, oauth2-proxy, dex)
   - `observability`: Monitoring (Prometheus, Grafana, Loki, Jaeger, Thanos)
   - `security-system`: Security (Kyverno, Falco, Gatekeeper, Crowdsec)
   - `istio-system` & `istio-ingress`: Service mesh
   - `home-system`: Home automation & media
   - `rook-ceph`: Storage
   - `business-system`: Business logic like odoo, nextcloud, magento

### HelmRelease Global Defaults
All HelmReleases are patched with these defaults via Kustomization:
```yaml
install:
  crds: CreateReplace
  createNamespace: true
  replace: true
  strategy: RetryOnFailure
  timeout: 10m
rollback:
  recreate: true
  force: true
  cleanupOnFail: true
upgrade:
  cleanupOnFail: true
  crds: CreateReplace
  remediation:
    remediateLastFailure: true
    retries: 3
    strategy: rollback
```

### Security Practices
- **Secret encryption**: SOPS with Age (primary) + GCP KMS backup
- **Never commit unencrypted secrets**: All secrets use `.enc.age.yaml` suffix
- **Policy enforcement**: Kyverno & OPA Gatekeeper
- **Runtime security**: Falco & Tetragon
- **Pod security labels**: Applied to all namespaces
- **Immutable OS**: Talos Linux minimal attack surface

## Development Workflow

### Bootstrap New Cluster
```bash
# 1. Set environment variables (CLUSTER_ID defaults to cluster-00)
# 2. Bootstrap Flux Operator
task fluxcd:bootstrap  # Installs flux-operator, flux-instance, cert-manager, kustomize-mutating-webhook

# 3. Install cluster secrets
task flux:secrets      # Decrypts and applies sops-gpg, sops-age, cluster-secrets, github-auth, cluster-config

# 4. Configure Talos
task talos:config      # Decrypts talosconfig to ~/.talos/config
```

### Remote Cluster Access

The cluster API is exposed via Cloudflare Tunnel for secure remote access. This requires `cloudflared` installed locally.

**Prerequisites:**
- Install cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/
- Have access to the email configured in Cloudflare Access (for OTP authentication)

**First-time setup (or when token expires ~24hrs):**
```bash
# Authenticate via browser (OTP sent to your email)
cloudflared access login api.haydenagencies.com.au
```

**Start the tunnel and use kubectl:**
```bash
# Start the tunnel (runs in background)
cloudflared access tcp --hostname api.haydenagencies.com.au --url 127.0.0.1:1234 &

# Use kubectl with SOCKS proxy
HTTPS_PROXY=socks5://127.0.0.1:1234 kubectl get nodes
```

**Optional shell alias** (add to `~/.bashrc` or `~/.zshrc`):
```bash
alias kubeone="env HTTPS_PROXY=socks5://127.0.0.1:1234 kubectl"
```

**Local network access:**
When on the same network as the cluster (192.168.50.x), use kubectl directly without the proxy:
```bash
kubectl get nodes
```

**Refreshing kubeconfig (from Talos):**
```bash
talosctl -n 192.168.50.11 kubeconfig --force
```

### TrueNAS Access
```bash
ssh truenas_admin@192.168.50.17
```
Uses `~/.ssh/rog_laptop_key` (configured globally in SSH config).

### Branch Protection

The `master` branch is protected with required status checks. Direct pushes are blocked.

**Required checks before merge:**
- `Flux Local - Success` - Validates Kubernetes manifests with flux-local
- `Security - Success` - Runs Trivy IaC, Semgrep SAST, and Gitleaks scans

**Settings:**
- Strict mode enabled (branch must be up-to-date with master)
- Admins can bypass in emergencies (`enforce_admins: false`)
- Force pushes and deletions disabled

**Workflow for changes:**
```bash
# Create branch, make changes, push
git checkout -b fix/my-change
# ... make changes ...
git add . && git commit -m "fix: description"
git push -u origin fix/my-change

# Create PR and merge (waits for CI)
gh pr create --fill
gh pr merge --auto --merge  # Auto-merges when checks pass
```

**Quick one-liner for simple fixes:**
```bash
git checkout -b fix/quick && git add . && git commit -m "fix: quick change" && git push -u origin fix/quick && gh pr create --fill && gh pr merge --auto --merge && git checkout master
```

### Making Changes to Applications
1. **Edit base configuration** in `kubernetes/apps/base/[system-name]/[app-name]/`
2. **Use overlays** for cluster-specific customization in `kubernetes/apps/overlays/cluster-00/`
3. **Follow naming conventions**:
   - `ks.yaml`: Flux Kustomization resources
   - `kustomization.yaml`: Kustomize configuration
   - `*.enc.yaml`: SOPS encrypted files
   - `helmrelease.yaml`: Helm release definitions
   - `ocirepository.yaml`: OCI repository sources
4. **Ensure secrets are encrypted** before committing (use `sops` command)
5. **Run pre-commit hooks**: `pre-commit run --all-files`
6. **FluxCD auto-reconciles** from master branch after push

### Adding New Applications
1. Create directory structure: `kubernetes/apps/base/[system-name]/[app-name]/`
2. Add `app/` directory with:
   - `helmrelease.yaml` (with `chartRef` to OCIRepository)
   - `ocirepository.yaml` (chart source)
   - `values.yaml` (Helm values)
   - `secret.enc.yaml` (if needed, encrypted with SOPS)
   - `kustomization.yaml`
3. Create `ks.yaml` with:
   - `dependsOn` for dependency chain
   - `decryption` for SOPS secrets
   - `postBuild.substituteFrom` for ConfigMap/Secret references
4. Add to parent `kustomization.yaml`
5. Create overlay if cluster-specific customization needed

### Syncing from Upstream

This repo is forked from [xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops). The `upstream-sync` workflow (`.github/workflows/upstream-sync.yaml`) automates syncing.

**Automatic Flow (daily at 6am Melbourne / 8pm UTC):**
1. Workflow fetches `upstream/main` and compares with `master`
2. Excludes local customizations (`.sops.yaml`, secrets, `CLAUDE.md`, renovate config)
3. If no conflicts: creates PR automatically with categorized change summary
4. If conflicts: reports them in workflow output with manual resolution steps

**Manual Sync (when conflicts exist):**
```bash
# 1. Ensure upstream remote exists and fetch
git remote add upstream https://github.com/xunholy/k8s-gitops.git 2>/dev/null || true
git fetch upstream main

# 2. Check what's changed from upstream
git diff --stat master...upstream/main

# 3. Create sync branch from master
git checkout master
git checkout -b upstream-sync/$(date +%Y-%m-%d)

# 4. Attempt merge (will report conflicts if any)
git merge upstream/main --no-edit

# 5. List conflicted files
git diff --name-only --diff-filter=U

# 6. Resolve each conflict - choose one:
git checkout --theirs <file>   # Take upstream version
git checkout --ours <file>     # Keep our version
# Or manually edit the file to resolve

# 7. Stage resolved files and complete merge
git add .
git commit --no-edit

# 8. Push branch
git push -u origin upstream-sync/$(date +%Y-%m-%d)

# 9. Create PR via gh CLI
gh pr create --repo mak011p/k8s-gitops-hayden --base master \
  --title "chore: sync with upstream xunholy/k8s-gitops" \
  --body "## Upstream Sync

Syncs changes from [xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops).

### Conflict Resolutions
- List resolved conflicts here

---
🤖 Generated manually"

# 10. Check PR status and merge when ready
gh pr checks <PR_NUMBER> --repo mak011p/k8s-gitops-hayden
gh pr merge <PR_NUMBER> --repo mak011p/k8s-gitops-hayden --merge --delete-branch

# 11. Return to master and pull
git checkout master
git pull
```

**Conflict Resolution Guidelines:**
| File Type | Typical Resolution |
|-----------|-------------------|
| GitHub Actions (checkout, etc.) | Take upstream (newer versions) |
| Helm chart versions | Take upstream (version bumps) |
| README.md (hardware table) | Keep ours (local config) |
| `.sops.yaml`, secrets | Keep ours (excluded anyway) |
| `CLAUDE.md` | Keep ours (excluded anyway) |

**Triggering Manual Sync:**
```bash
gh workflow run upstream-sync.yaml -f dry_run=false
```

## Important Patterns & Conventions

### File Naming
- `ks.yaml`: Flux Kustomization resources (defines how to apply manifests)
- `kustomization.yaml`: Kustomize configuration (defines what resources to include)
- `*.enc.age.yaml`: SOPS-encrypted with Age
- `helmfile.yaml`: Helmfile configurations (used in bootstrap)
- `helmrelease.yaml`: Helm release definitions
- `ocirepository.yaml`: OCI repository sources for Helm charts
- `namespace.yaml`: Namespace definitions with pod security labels

### Kustomization Labels
- `substitution.flux/enabled=true`: Enables SOPS decryption and variable substitution
- Patches applied globally to all Kustomizations for HelmRelease defaults

### Namespace Conventions
Labels applied to namespaces:
- `pod-security.kubernetes.io/enforce: privileged` (or `restricted`/`baseline`)
- `goldilocks.fairwinds.com/enabled: "true"` (monitoring)
- `kustomize.toolkit.fluxcd.io/prune: disabled` (on flux-system)

### Dependency Management
Flux Kustomizations use `dependsOn` to establish deployment order:
```yaml
dependsOn:
  - name: cert-manager
    namespace: flux-system
```

## Important Notes

- **Cluster ID**: "cluster-00" is the default cluster identifier
- **Branch**: `master` is the primary branch (auto-reconciled by FluxCD)
- **Talos configs**: Stored encrypted in `talos/generated/`
- **Bootstrap method**: Uses Flux Operator (not traditional `flux bootstrap`)
- **Chart sources**: Uses OCIRepository instead of HelmRepository
- **Yamllint config**: Line length warning at 240 characters, 2-space indentation
- **Renovate automation**: Auto-merge enabled for digests, ignores encrypted files
- **Multi-cluster ready**: Designed with overlay pattern for multiple clusters
- **Enterprise patterns**: Production-grade GitOps implementation showcasing CNCF ecosystem

## External Dependencies

- **Cloudflare**: DNS management and CDN services
- **Google Cloud Platform**:
  - GCP KMS for SOPS encryption
  - Google Cloud Storage for Thanos long-term metrics storage
  - Google Cloud Storage for Velero backups
  - OAuth for authentication
- **GitHub**: Source control, authentication, and OCI registry for Helm charts
- **SOPS/Age**: Secret encryption (requires Age key setup)
- **Task**: Task runner (must be installed locally)
- **Helmfile**: Used for bootstrap process
- **Let's Encrypt**: Certificate generation for secure communication
- **NextDNS**: Malware protection and ad-blocking
- **UptimeRobot**: Service monitoring

## Troubleshooting with Flux MCP

This repository includes Cursor rules for troubleshooting Flux resources using the `flux-operator-mcp` tools. Key troubleshooting workflows:

### Analyzing HelmReleases
1. Check helm-controller status with `get_flux_instance`
2. Get HelmRelease resource and analyze spec, status, inventory, events
3. Check `valuesFrom` ConfigMaps and Secrets
4. Verify source (OCIRepository) status
5. Analyze managed resources from inventory
6. Check logs if resources are failing

### Analyzing Kustomizations
1. Check kustomize-controller status with `get_flux_instance`
2. Get Kustomization resource and analyze spec, status, inventory, events
3. Check `substituteFrom` ConfigMaps and Secrets
4. Verify source (GitRepository/OCIRepository) status
5. Analyze managed resources from inventory

### Comparing Resources Across Clusters
Use `get_kubernetes_contexts` and `set_kubernetes_context` to switch between clusters, then compare resource specs and status.

## Replacing a Talos Worker Node (with Rook Ceph OSD)

### Steps
1. **Cordon & drain**: `kubectl cordon worker1 && kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data --force`
2. **Remove OSD from Ceph**: `ceph osd out <id> && ceph osd down <id> && ceph osd purge <id> --yes-i-really-mean-it`
3. **Delete OSD deployment**: `kubectl delete deploy rook-ceph-osd-<id> -n rook-ceph`
4. **Update network patch**: Edit `talos/patches/worker<N>-network.yaml` with new NIC interface and disk selector
5. **Apply config**: `sops exec-file talos/generated/node.enc.yaml 'talosctl apply-config --insecure -n <NEW_IP> --config-patch @talos/patches/worker<N>-network.yaml --file {}'`
6. **Uncordon**: `kubectl uncordon worker1`

### Common Roadblocks

| Issue | Fix |
|-------|-----|
| Rook stuck in "Draining Failure Domain" | Delete configmap: `kubectl delete cm rook-ceph-pdbstatemap -n rook-ceph` |
| Old mon crashing on new node | Remove mon: `ceph mon remove <id>` then delete deployment |
| OSD prepare job not created | Cluster must finish "Configuring Ceph Mons" before OSD provisioning starts |
| Cluster stuck on mon config | Ensure 3 healthy mons in quorum before OSDs will provision |

### Verify Success
```bash
ceph osd tree    # New OSD should be up
ceph -s          # PGs should be active+clean, 3 OSDs in cluster
```

## OAuth2 + Envoy Gateway External Authorization

This cluster uses **oauth2-proxy** with **Dex** (OIDC provider) for authentication, protected by Envoy Gateway's **SecurityPolicy** with external authorization (ext_authz).

### Architecture Flow
```
User Request → Envoy Gateway → SecurityPolicy (ext_authz) → oauth2-proxy
                                      ↓
                              oauth2-proxy validates cookie
                                      ↓
                    If no cookie: redirect to Dex → GitHub OAuth → callback
                    If valid cookie: allow request to backend
```

### Critical Configuration Requirements

#### 1. SecurityPolicy must forward cookies to ext_authz
Without `headersToExtAuth`, the session cookie won't be sent to oauth2-proxy during auth checks, causing an **infinite login loop**.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
spec:
  extAuth:
    failOpen: false
    headersToExtAuth:        # REQUIRED - at extAuth level, NOT under http
      - cookie
      - authorization
    http:
      backendRefs:
        - name: oauth2-proxy
          namespace: network-system
          port: 80
      headersToBackend:      # Headers from oauth2-proxy to backend
        - x-auth-request-user
        - x-auth-request-email
        - x-auth-request-groups
        - authorization
```

#### 2. oauth2-proxy must not force consent prompts
If oauth2-proxy sends `prompt=consent`, Dex will show the approval screen even with `skipApprovalScreen: true`.

```yaml
# In oauth2-proxy HelmRelease values
config:
  configFile: |
    prompt = ""              # Empty string - don't override Dex settings
    skip_provider_button = true
```

#### 3. Dex must have skipApprovalScreen enabled
```yaml
# In Dex values
config:
  oauth2:
    skipApprovalScreen: true
    alwaysShowLoginScreen: false
```

#### 4. HTTPRoute must handle /oauth2/* callbacks
The main HTTPRoute (not the admin route) must route `/oauth2/*` to oauth2-proxy for callbacks:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2/
      backendRefs:
        - name: oauth2-proxy
          namespace: network-system
          port: 80
```

### Common Issues and Symptoms

| Symptom | Cause | Fix |
|---------|-------|-----|
| Infinite login loop (auth succeeds but redirects to login again) | `headersToExtAuth` missing - cookie not forwarded to oauth2-proxy | Add `headersToExtAuth: [cookie, authorization]` to SecurityPolicy |
| Dex approval screen shows despite `skipApprovalScreen: true` | oauth2-proxy sending `prompt=consent` | Set `prompt = ""` in oauth2-proxy config |
| "Grant Access" button does nothing | Stale auth request (expired CSRF token) | Clear cookies and start fresh |
| `dry-run failed: field not declared in schema` | `headersToExtAuth` at wrong level or wrong EG version | Ensure field is under `extAuth`, not `extAuth.http` |

### Debugging Commands
```bash
# Check oauth2-proxy logs for auth flow
kubectl logs -n network-system -l app.kubernetes.io/name=oauth2-proxy --tail=50

# Check Dex logs for login events
kubectl logs -n network-system -l app.kubernetes.io/name=dex --tail=50

# Verify SecurityPolicy configuration
kubectl get securitypolicy -n <namespace> <name> -o yaml | grep -A10 headersToExtAuth

# Check if cookie is being set (look for Set-Cookie in callback response)
# In browser DevTools: Network tab → filter by /oauth2/callback
```

### Reference
- [Envoy Gateway External Authorization](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
- [Authelia + Envoy Gateway Integration](https://www.authelia.com/integration/kubernetes/envoy/gateway/)
- [Dex OAuth2 Configuration](https://dexidp.io/docs/configuration/oauth2/)
