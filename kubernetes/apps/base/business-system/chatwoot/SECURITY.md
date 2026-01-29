# Chatwoot Security Hardening

Security audit performed 2026-01-29. All changes are declarative and managed via GitOps (FluxCD).

## Network Policies

### chatwoot-app (Egress-only)

Restricts what chatwoot web and worker pods can connect to:

| Destination | Port | Purpose |
|-------------|------|---------|
| kube-system/kube-dns | 53 UDP/TCP | DNS resolution |
| business-system/chatwoot-pg | 5432 TCP | PostgreSQL (CNPG) |
| database-system/redis | 6379 TCP | Redis (shared instance) |
| External (non-RFC1918) | 587, 465, 443 TCP | SMTP and outbound HTTPS |

**Why egress-only (no ingress enforcement):**
Cilium intermittently drops UDP DNS response packets when ingress policy is enforced. UDP conntrack entries have short timeouts, causing a race condition where DNS responses arrive after the entry expires. This causes DNS resolution failures during Rails boot, leading to Redis/Postgres connection timeouts and CrashLoopBackOff. Egress rules provide the primary security value; ingress to port 3000 is already controlled by Envoy Gateway and SecurityPolicy.

### chatwoot-migrate (Egress-only)

Restricts the database migration job to DNS, PostgreSQL, and Redis only.

### chatwoot-pg (Ingress + Egress)

Restricts PostgreSQL (CNPG) pod connectivity:

- **Ingress:** Chatwoot app pods (5432), migrate job (5432), CNPG replication (5432 + 8000), Prometheus (9187)
- **Egress:** DNS, CNPG replication (5432 + 8000), external HTTPS for GCS backups (443)

**Note:** Port 8000 is required for CNPG instance manager health checks and failover coordination between replicas. Without it, CNPG reports `Instance Status Extraction Error: HTTP communication issue` and PostgreSQL becomes unresponsive.

### chatwoot-pg-apiserver (CiliumNetworkPolicy)

Allows CNPG pods to reach the Kubernetes API server using Cilium's `toEntities: kube-apiserver`. Standard NetworkPolicy `ipBlock` rules don't work for K8s API access with Cilium CNI because the API server identity is managed differently.

## Authentication

- `/super_admin` route protected by oauth2-proxy + Dex via Envoy Gateway SecurityPolicy (`chatwoot-admin-auth`)
- Main app uses Chatwoot's built-in authentication

## Rate Limiting

**Not currently active.** Global rate limiting requires `rateLimit` to be enabled in the EnvoyGateway config resource. Without it, `BackendTrafficPolicy` with global rate limit rules causes Envoy Gateway to return 500 on all affected routes.

To enable rate limiting in the future:

1. Configure `rateLimit` in the EnvoyGateway resource (requires a Redis backend for the rate limit service)
2. Re-add `BackendTrafficPolicy` resources targeting the chatwoot HTTPRoutes
3. Add `backendtrafficpolicy.yaml` back to `app/kustomization.yaml`

## Known Constraints

- **Redis timeout:** Chatwoot hardcodes `timeout: 1` and `reconnect_attempts: 2` in `lib/redis/config.rb` with no environment variable override. Cross-node connections occasionally exceed 1 second during pod startup. The DNS fix (removing ingress enforcement) resolved the startup failures, but if Redis latency increases, pods may need multiple restarts to boot successfully.

- **Cilium + K8s NetworkPolicy + UDP:** Cilium's conntrack for UDP has short entry timeouts. Avoid combining strict ingress enforcement with egress DNS rules on the same NetworkPolicy if pods depend on DNS during startup. Use egress-only or CiliumNetworkPolicy for more reliable behavior.

## Commits

| Commit | Description |
|--------|-------------|
| `1107b9e90` | Remove Redis auth and restore Postgres password |
| `579f40291` | Use CiliumNetworkPolicy for CNPG K8s API egress |
| `2e87d5b70` | Add control plane IPs for K8s API egress (superseded by CiliumNetworkPolicy) |
| `25c92f32c` | Allow CNPG instance manager port 8000 in network policy |
| `0b2dfef7d` | Remove ingress policy that blocks DNS responses |
| `fe4f8e2f7` | Remove rate limit policies causing 500 errors |
