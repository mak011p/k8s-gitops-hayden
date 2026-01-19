# Magento 2.4.7 Kubernetes Deployment Plan

## Overview

Deploy **auntalma.com.au** Magento 2.4.7-p7 store to the GitOps cluster using established FluxCD patterns.

**Strategy**: Deploy dev environment first → verify everything works → migrate production data

## Architecture Summary

| Component | Solution | Version | Storage |
|-----------|----------|---------|---------|
| Magento App | Custom Docker image + app-template | 2.4.7-p7 | - |
| PHP-FPM | ghcr.io/hayden-agencies/magento-auntalma | 8.3 | - |
| Database | MariaDB Operator (Galera HA) | 10.6 | 100Gi ceph-block |
| Cache/Sessions | Redis (embedded Bitnami) | 7.2 | 5Gi ceph-block |
| Search | Elasticsearch 7.17 + Algolia | 7.17 | 50Gi ceph-block |
| Message Queue | RabbitMQ (Bitnami) | 3.13 | 10Gi ceph-block |
| Media Storage | CephFS (RWX) | - | 100Gi ceph-filesystem |
| Var Storage | CephFS (RWX) | - | 50Gi ceph-filesystem |

**Note**: Both Elasticsearch (backend catalog) and Algolia (frontend search) are configured in dev.

## Key Decisions

### 1. Helm Chart: Custom app-template (like Odoo)
- Pre-built charts (Bitnami deprecated, PHOENIX-MEDIA) bundle dependencies - conflicts with cluster patterns
- Custom modules (21+ Rival namespace) require custom Docker image anyway
- Aligns with existing Odoo deployment pattern

### 2. Database: MariaDB Operator
- CNPG doesn't support MySQL; Magento requires MySQL/MariaDB
- Provides HA via Galera Cluster (3-node)
- Supports backups to GCS (like CNPG Barman)
- New operator in `database-system` namespace

### 3. Storage: CephFS for Media (RWX)
- Enables horizontal pod scaling
- `ceph-block` for database and Redis (performance)
- `ceph-filesystem` for shared media/var directories

## Directory Structure

```
kubernetes/apps/base/
├── database-system/
│   ├── mariadb-operator/           # NEW: Operator + CRDs
│   │   ├── crds/
│   │   │   ├── ks.yaml
│   │   │   └── app/
│   │   │       ├── helmrelease.yaml
│   │   │       ├── helmrepository.yaml
│   │   │       └── kustomization.yaml
│   │   └── app/
│   │       ├── ks.yaml
│   │       ├── helmrelease.yaml
│   │       └── kustomization.yaml
│
├── business-system/
│   ├── auntalma/                   # NEW: Magento for auntalma.com.au
│   │   ├── ks.yaml
│   │   └── app/
│   │       ├── mariadb-cluster.yaml
│   │       ├── helmrelease.yaml
│   │       ├── ocirepository.yaml
│   │       ├── configmap-nginx.yaml
│   │       ├── configmap-php.yaml
│   │       ├── pvc-media.yaml
│   │       ├── pvc-var.yaml
│   │       ├── httproute.yaml
│   │       ├── podmonitor.yaml
│   │       ├── prometheusrule.yaml
│   │       ├── externalsecret-ghcr.yaml
│   │       ├── secret-magento-app.enc.age.yaml
│   │       ├── secret-mariadb-app.enc.age.yaml
│   │       ├── secret-mariadb-superuser.enc.age.yaml
│   │       ├── replicationsource.yaml
│   │       └── kustomization.yaml
│   │
│   ├── auntalma-elasticsearch/     # NEW: Elasticsearch 7.17
│   │   ├── ks.yaml
│   │   └── app/
│   │       ├── helmrelease.yaml
│   │       ├── ocirepository.yaml
│   │       └── kustomization.yaml
│   │
│   └── auntalma-rabbitmq/          # NEW: RabbitMQ 3.13
│       ├── ks.yaml
│       └── app/
│           ├── helmrelease.yaml
│           ├── ocirepository.yaml
│           ├── secret.enc.age.yaml
│           └── kustomization.yaml

terraform/cloudflare/
└── auntalma.tf                     # UPDATE: Add web DNS records
```

## Dependency Chain

```
1. mariadb-operator-crds
   └── 2. mariadb-operator
       └── 3. auntalma (creates MariaDB cluster)

1. rook-ceph-cluster (existing)
   ├── 2. auntalma-elasticsearch
   ├── 2. auntalma-rabbitmq
   └── 2. auntalma (PVCs)

1. onepassword (existing) → 2. auntalma (ExternalSecrets)
1. cilium-gateway-api (existing) → 2. auntalma (HTTPRoute)
```

## Resource Requirements

| Component | CPU Request | Memory Request | Memory Limit | Replicas |
|-----------|-------------|----------------|--------------|----------|
| Auntalma PHP-FPM | 500m | 2Gi | 8Gi | 2 |
| Auntalma Nginx | 100m | 128Mi | 512Mi | 2 (sidecar) |
| Auntalma Cron | 100m | 512Mi | 2Gi | CronJob |
| MariaDB Galera | 500m | 2Gi | 8Gi | 3 |
| Redis | 100m | 256Mi | 1Gi | 1 |
| Elasticsearch | 250m | 1Gi | 2Gi | 1 |
| RabbitMQ | 100m | 256Mi | 1Gi | 1 |

**Total**: ~3 CPU cores, ~11Gi memory requested, ~315Gi storage

## Implementation Strategy

### Stage 1: Dev Environment on K8s

#### Phase 1: Infrastructure
1. Deploy MariaDB Operator to database-system
2. Deploy Elasticsearch and RabbitMQ to business-system
3. Create MariaDB Galera cluster for auntalma
4. Verify all services healthy

#### Phase 2: Docker Image Build
1. Create Dockerfile based on dev setup (PHP 8.3-FPM + Nginx)
2. Include all Rival custom modules + composer dependencies
3. Set up GitHub Actions workflow → push to GHCR
4. Configure Renovate for digest tracking

#### Phase 3: Deploy Dev Data
1. Import dev database to K8s MariaDB
2. Copy dev media files to CephFS PVC
3. Deploy Magento HelmRelease
4. Update `core_config_data` for cluster URLs
5. Reindex Elasticsearch
6. Verify storefront + admin functionality

#### Phase 4: Validate
1. Test checkout flow (Stripe/eWay)
2. Test Algolia search
3. Test admin operations
4. Verify cron jobs running
5. Check Prometheus metrics

### Stage 2: Production Migration (Later)
Once dev is validated:
1. Take production database backup
2. Sync media files from production server
3. Import production data to K8s
4. Update DNS (auntalma.com.au → cluster)
5. Monitor and verify

## Build Pipeline

Custom Docker image built via GitHub Actions:
- Base: PHP 8.3-FPM + Nginx
- Includes: All 21+ Rival custom modules
- Includes: Composer dependencies (Stripe, Amasty, Fooman, etc.)
- Push to: ghcr.io/hayden-agencies/magento
- Renovate tracks digest updates

## Verification Checklist

1. All pods in `business-system` namespace running
2. MariaDB Galera cluster shows 3/3 nodes synced (`SHOW STATUS LIKE 'wsrep_cluster_size'`)
3. `curl https://auntalma.haydenagencies.com.au/health_check.php` returns 200
4. Admin login works at `/admin_hayden/`
5. Product search returns results (Elasticsearch reindex complete)
6. Algolia autocomplete working on frontend
7. Test order placement (RabbitMQ queue processing)
8. Cron jobs executing (`bin/magento cron:run` logs)
9. Prometheus metrics appearing in Grafana
10. VolSync backup completing successfully

## DNS Configuration (Terraform)

Add to `terraform/cloudflare/auntalma.tf`:
```hcl
# Web traffic via Cloudflare Tunnel
resource "cloudflare_record" "auntalma_web" {
  zone_id = local.auntalma_zone_id
  name    = "@"
  content = "external.haydenagencies.com.au"
  type    = "CNAME"
  proxied = true
  comment = "Magento store via K8s cluster"
}

resource "cloudflare_record" "auntalma_www" {
  zone_id = local.auntalma_zone_id
  name    = "www"
  content = "external.haydenagencies.com.au"
  type    = "CNAME"
  proxied = true
  comment = "Magento store www redirect"
}
```

## Decisions Made

| Decision | Choice |
|----------|--------|
| Domain | auntalma.com.au |
| Database | MariaDB Galera 3-node HA |
| Search | Elasticsearch 7.17 + Algolia |
| Media Storage | 100Gi (under 50GB needed) |
| Approach | Dev environment first, then production |

## Files to Create (Summary)

### database-system (MariaDB Operator)
- `mariadb-operator/crds/ks.yaml`
- `mariadb-operator/crds/app/helmrelease.yaml`
- `mariadb-operator/crds/app/helmrepository.yaml`
- `mariadb-operator/crds/app/kustomization.yaml`
- `mariadb-operator/app/ks.yaml`
- `mariadb-operator/app/helmrelease.yaml`
- `mariadb-operator/app/kustomization.yaml`

### business-system (Auntalma)
- `auntalma/ks.yaml`
- `auntalma/app/mariadb-cluster.yaml`
- `auntalma/app/helmrelease.yaml`
- `auntalma/app/ocirepository.yaml`
- `auntalma/app/configmap-nginx.yaml`
- `auntalma/app/configmap-php.yaml`
- `auntalma/app/pvc-media.yaml`
- `auntalma/app/pvc-var.yaml`
- `auntalma/app/httproute.yaml`
- `auntalma/app/secret-*.enc.age.yaml` (3 files)
- `auntalma/app/kustomization.yaml`
- `auntalma-elasticsearch/ks.yaml`
- `auntalma-elasticsearch/app/helmrelease.yaml`
- `auntalma-elasticsearch/app/ocirepository.yaml`
- `auntalma-elasticsearch/app/kustomization.yaml`
- `auntalma-rabbitmq/ks.yaml`
- `auntalma-rabbitmq/app/helmrelease.yaml`
- `auntalma-rabbitmq/app/ocirepository.yaml`
- `auntalma-rabbitmq/app/secret.enc.age.yaml`
- `auntalma-rabbitmq/app/kustomization.yaml`

### Terraform
- Update `terraform/cloudflare/auntalma.tf` with web records

### External (Magento Source Repo)
- Dockerfile for custom image
- GitHub Actions workflow for GHCR builds
