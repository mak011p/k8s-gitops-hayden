# Magento Production Migration Guide

Reference document for migrating Magento production data from VPS into the Kubernetes cluster.
Based on the auntalma.com.au migration (Feb 2026).

## Overview

**Source:** VPS at `web@103.21.131.100:22222` (SSH key: `~/.ssh/rog_laptop_key`)
**Target:** MariaDB Galera cluster + Magento pods in `business-system` namespace
**Strategy:** Test with `*.haydenagencies.com.au` subdomain first, then cutover to production domain

## Issues Encountered & Resolutions

### 1. MariaDB Galera CrashLoopBackOff After Operator Upgrade

**Symptom:** All 3 Galera nodes in CrashLoopBackOff after mariadb-operator upgrade to v25.10.4.

**Root Cause:** Renovate bumped the operator but the CRD field `automaticFailover` was renamed to `autoFailover` in the new version.

**Fix:** Update `mariadb-cluster.yaml`:
```yaml
# Before (broken)
galera:
  primary:
    automaticFailover: true

# After (fixed)
galera:
  primary:
    autoFailover: true
```

Also update agent/initContainer images to match operator version:
```yaml
agent:
  image: docker-registry3.mariadb.com/mariadb-operator/mariadb-operator:25.10.4
initContainer:
  image: docker-registry3.mariadb.com/mariadb-operator/mariadb-operator:25.10.4
```

**Resolution:** Nuked PVCs and fresh-started since we were importing production data anyway.

---

### 2. MariaDB 12.1 Incompatible with Magento 2.4.7

**Symptom:** `setup:upgrade` fails with:
```
Current version of RDBMS is not supported. Used Version: 12.1.2-MariaDB-ubu2404.
Supported versions: MySQL-8, MySQL-5.7, MariaDB-(10.2-10.11)
```

**Root Cause:** Renovate auto-upgraded `mariadb:10.11` to `mariadb:12.1`. Magento 2.4.7 only supports MariaDB 10.2-10.11.

**Temporary Fix (lost on pod restart):** Patch the `SqlVersionProvider` DI config in the container:
```bash
kubectl exec $POD -n business-system -c php -- sed -i \
  '/MariaDB-(10.2-10.11)/a\                <item name="MariaDB-12" xsi:type="string">^12\.<\/item>' \
  /var/www/html/vendor/magento/magento2-base/app/etc/di.xml

kubectl exec $POD -n business-system -c php -- sed -i \
  '/MariaDB-(10.2-10.11)/a\                <item name="MariaDB-12" xsi:type="string">^12\.<\/item>' \
  /var/www/html/app/etc/di.xml
```

**IMPORTANT:** You MUST also clear generated code after patching:
```bash
kubectl exec $POD -n business-system -c php -- bash -c \
  "rm -rf /var/www/html/generated/code/* /var/www/html/generated/metadata/* /var/www/html/var/cache/* /var/www/html/var/di/*"
```

**Permanent Fix Needed:** Either:
- Pin `mariadb:10.11` in `mariadb-cluster.yaml` and add Renovate ignore rule
- OR bake the di.xml patch into the Magento Docker image

---

### 3. Database Import: kubectl exec Pipe Timeout

**Symptom:** Piping SQL dump (161 MB) through `kubectl exec` times out:
```
error: unable to upgrade connection: i/o timeout
```

**Root Cause:** Streaming large files through the K8s API server is unreliable.

**Fix:** Copy the dump into the pod first, then import locally:
```bash
# Step 1: Copy dump into pod
kubectl cp /tmp/auntalma_dump.sql business-system/auntalma-mariadb-0:/tmp/auntalma_dump.sql -c mariadb

# Step 2: Import locally inside the container
kubectl exec auntalma-mariadb-0 -n business-system -c mariadb -- \
  mariadb -u root -p"${ROOT_PW}" magento < /tmp/auntalma_dump.sql
```

---

### 4. Database Import: LOCK TABLES Error with Galera

**Symptom:** Import fails with:
```
ERROR 1100 (HY000): Table 'rating_option_vote' was not locked with LOCK TABLES
```

**Root Cause:** mysqldump includes `LOCK TABLES` / `UNLOCK TABLES` statements. Galera doesn't support `LOCK TABLES` in normal transaction flow.

**Fix:** Strip lock statements from the dump before importing:
```bash
# Option A: Pipe through sed
cat /tmp/auntalma_dump.sql | sed '/^LOCK TABLES/d; /^UNLOCK TABLES/d' | \
  kubectl exec -i auntalma-mariadb-0 -n business-system -c mariadb -- \
  mariadb -u root -p"${ROOT_PW}" magento

# Option B: Clean the file first
sed -i '/^LOCK TABLES/d; /^UNLOCK TABLES/d' /tmp/auntalma_dump.sql
```

---

### 5. MariaDB CLI Binary Name Change

**Symptom:** `mysql` command not found in MariaDB 12.1 container.

**Root Cause:** MariaDB 12.1 renamed the CLI binary from `mysql` to `mariadb`.

**Fix:** Use `mariadb` instead of `mysql` in all exec commands:
```bash
# Before (broken on 12.1)
kubectl exec ... -- mysql -u root ...

# After (works on 12.1)
kubectl exec ... -- mariadb -u root ...
```

---

### 6. MAGE_RUN_CODE Mismatch

**Symptom:** `setup:upgrade` fails with:
```
website with code auntalma that was requested wasn't found
```

**Root Cause:** The HelmRelease had `MAGE_RUN_CODE=auntalma` but the production database uses `base` as the website code for Aunt Alma.

**Discovery:** Query the production DB to find actual website codes:
```sql
SELECT website_id, code, name FROM store_website;
-- Results: admin(0), base(1=Aunt Alma), drop_drape_second_site(2)

SELECT store_id, code, website_id, name FROM store;
-- Results: admin(0), default(1=Aunt Alma), drop_drape_store_view(2)
```

**Fix:** Update `MAGE_RUN_CODE` in helmrelease.yaml to match the production DB:
```yaml
- name: MAGE_RUN_CODE
  value: base  # NOT "auntalma" - must match store_website.code
```

**Lesson:** Always check `store_website` and `store` tables after import to find the correct codes.

---

### 7. Alpine/musl DNS Resolution Failure (.local domains)

**Symptom:** PHP can't connect to services:
```
php_network_getaddresses: getaddrinfo for auntalma-mariadb-primary.business-system.svc.cluster.local failed: Try again
```

But `nslookup` from the same pod works fine. Short hostnames also work:
```php
gethostbyname('auntalma-mariadb-primary');  // Returns 10.110.12.97 (works!)
gethostbyname('auntalma-mariadb-primary.business-system.svc.cluster.local');  // Returns the hostname itself (FAILS!)
```

**Root Cause:** Alpine Linux uses musl libc, which has a known bug with `.local` TLD. musl treats `.local` as mDNS and fails to resolve via standard DNS.

**Fix:** Use short service names instead of FQDNs in helmrelease.yaml env vars. Since pods and services are in the same namespace (`business-system`), the search domain automatically appends the rest:
```yaml
# Before (broken on Alpine/musl)
- name: MAGENTO_DB_HOST
  value: auntalma-mariadb-primary.business-system.svc.cluster.local

# After (works on Alpine/musl)
- name: MAGENTO_DB_HOST
  value: auntalma-mariadb-primary
```

Apply to ALL service hostnames: MariaDB, Redis, Elasticsearch, RabbitMQ.

---

### 8. Stale Elasticsearch Config in Database

**Symptom:** `setup:upgrade` fails with:
```
Could not validate a connection to Elasticsearch. No alive nodes found in your cluster
```

**Root Cause:** The production database has ES config in `core_config_data` pointing to the old Elastic Cloud instance (e.g., `magento-2-43eba1.es.ap-southeast-2.aws.found.io:9243` with auth enabled). This DB-stored config overrides whatever is in `env.php`.

**Fix:** Update ES config in the database:
```sql
UPDATE core_config_data SET value = 'auntalma-elasticsearch-es-http'
  WHERE path = 'catalog/search/elasticsearch7_server_hostname';
UPDATE core_config_data SET value = '9200'
  WHERE path = 'catalog/search/elasticsearch7_server_port';
UPDATE core_config_data SET value = '0'
  WHERE path = 'catalog/search/elasticsearch7_enable_auth';
UPDATE core_config_data SET value = ''
  WHERE path LIKE 'catalog/search/elasticsearch7_username';
UPDATE core_config_data SET value = ''
  WHERE path LIKE 'catalog/search/elasticsearch7_password';
```

**IMPORTANT:** Also flush Redis after changing DB config (see next issue).

**Note:** `env.php` sets ES config via `getenv('MAGENTO_ES_HOST')` under the `system.default.catalog.search` key, but the DB-stored `core_config_data` takes precedence for already-configured instances.

---

### 9. Redis Caching Stale Config

**Symptom:** After updating ES config in the DB, `setup:upgrade` still fails with the old Elastic Cloud hostname.

**Root Cause:** Magento caches its configuration in Redis. The stale ES config is served from Redis cache, not from the DB.

**Fix:** Flush the relevant Redis databases:
```bash
# From the PHP pod:
kubectl exec $POD -n business-system -c php -- php -r "
\$r = new Redis();
\$r->connect('auntalma-redis-master', 6379);
\$r->select(6); \$r->flushDB();  // DB 6 = Magento cache
\$r->select(1); \$r->flushDB();  // DB 1 = Page cache
echo 'Flushed Redis DBs 6 and 1';
"
```

**Lesson:** Always flush Redis after changing any `core_config_data` values.

---

### 10. Trigger Privilege Error with Galera Binary Logging

**Symptom:** `setup:upgrade` fails during schema updates:
```
SQLSTATE[HY000]: General error: 1419 You do not have the SUPER privilege and binary logging is enabled
(you *might* want to use the less safe log_bin_trust_function_creators variable),
query was: DROP TRIGGER IF EXISTS `trg_catalog_category_entity_after_insert`
```

**Root Cause:** Galera uses `binlog_format=ROW` for replication. Creating/dropping triggers requires SUPER privilege or `log_bin_trust_function_creators=1`.

**Fix:** Add to `mariadb-cluster.yaml` myCnf (permanent):
```yaml
myCnf: |
  [mariadb]
  ...
  log_bin_trust_function_creators=1
```

Also set at runtime (immediate, doesn't require MariaDB restart):
```bash
kubectl exec auntalma-mariadb-0 -n business-system -c mariadb -- \
  mariadb -u root -p"${ROOT_PW}" -e "SET GLOBAL log_bin_trust_function_creators=1;"
```

---

### 11. Flux Rollback Loop (Chicken-and-Egg)

**Symptom:** Flux deploys new pods with updated env vars, but Magento fails health checks (because `setup:upgrade` hasn't run), so Flux rolls back to the old template.

**Root Cause:** Magento can't serve HTTP until the DB schema is up to date. But the new pods need to serve HTTP to pass health checks. And you can't run `setup:upgrade` on old pods with new env vars easily.

**Workaround:** Run `setup:upgrade` on the current (old) pod with env var overrides:
```bash
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=auntalma-mariadb-primary
export MAGENTO_SESSION_REDIS_HOST=auntalma-redis-master
export MAGENTO_CACHE_REDIS_HOST=auntalma-redis-master
export MAGENTO_PAGE_CACHE_REDIS_HOST=auntalma-redis-master
export MAGENTO_ES_HOST=auntalma-elasticsearch-es-http
export MAGENTO_AMQP_HOST=auntalma-rabbitmq
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento setup:upgrade
"
```

Once setup:upgrade completes, the schema is updated in the DB, and new pods deployed by Flux will be able to serve.

**Alternative:** Suspend the HelmRelease temporarily:
```bash
flux suspend helmrelease auntalma -n business-system
# ... run setup:upgrade ...
flux resume helmrelease auntalma -n business-system
```

---

### 12. Multi-Store Discovery

**Finding:** The production database contains multiple stores:
- **website 1 (code: `base`)**: auntalma.com.au
- **website 2 (code: `drop_drape_second_site`)**: magento.toemass.com / dropdrape.com.au

The K8s deployment is single-store (`MAGE_RUN_CODE=base`, nginx `server_name _`). Multi-store requires:
- Nginx hostname-to-store-code mapping
- env.php changes to read store code from HTTP headers
- Separate DNS entries and HTTPRoutes
- Deferred to follow-up task

### 13. setup:upgrade Requires di:compile Afterwards

**Symptom:** After `setup:upgrade` succeeds, `indexer:reindex` fails with:
```
There are no commands defined in the "indexer" namespace.
```

**Root Cause:** `setup:upgrade` clears the generated DI code and outputs:
```
Please re-run Magento compile command. Use the command "setup:di:compile"
```

Without compiled DI, most Magento CLI commands are unavailable.

**Fix:** Always run `setup:di:compile` after `setup:upgrade`:
```bash
php bin/magento setup:di:compile
```

**Note:** `di:compile` takes several minutes and is CPU-intensive. It regenerates all interceptors/proxies/factories in `generated/code/`.

---

### 14. Flux Pods Replaced Mid-Migration

**Symptom:** While running manual setup commands via `kubectl exec`, the target pod disappears:
```
Error from server (NotFound): pods "auntalma-xxxxx" not found
```

**Root Cause:** Flux HelmRelease reconciliation replaces pods on every cycle (rollback, upgrade, or config change). Your exec session is killed mid-operation.

**Workaround:** Suspend the HelmRelease before starting manual migration steps:
```bash
flux suspend helmrelease auntalma -n business-system
# ... run all setup commands ...
flux resume helmrelease auntalma -n business-system
```

**Alternative:** Work fast and re-apply patches each time pods rotate. The DB changes (schema, config) persist across pod restarts — only the di.xml patch and generated code are lost.

---

### 15. env.php Missing `install.date` Key

**Symptom:** After `di:compile` succeeds, `indexer:reindex` fails with:
```
There are no commands defined in the "indexer" namespace.
```

`setup:db:status` reports: "No information is available: the Magento application is not installed."

Only base commands (setup, admin, module, etc.) appear in `php bin/magento list` — no `indexer`, `cache`, `cron`, `catalog`, etc.

**Root Cause:** The env.php ConfigMap was missing the `install` key. Magento checks `install/date` in `env.php` to determine if the application is installed. Without it, most module CLI commands are not registered.

**Fix:** Add to the env.php ConfigMap:
```php
'install' => [
    'date' => 'Sat, 01 Jan 2022 00:00:00 +0000',
],
```

**Important:** env.php is a read-only ConfigMap subPath mount — you CANNOT modify it in-container. You must update the ConfigMap resource, then restart the pod.

---

### 16. `pub/static` EmptyDir — No Static Content on Pod Start

**Symptom:** Storefront returns Magento 404 page. Exception log shows:
```
Unable to retrieve deployment version of static files from the file system.
```

`pub/static/deployed_version.txt` does not exist. `pub/static/` is empty.

**Root Cause:** The HelmRelease mounts `pub/static` as an `emptyDir` volume (shared between PHP and nginx containers for static file serving). This **hides the Docker image's baked-in static content** with an empty directory. There is no init container to copy or regenerate the static files.

**Fix needed:** Add an init container to the HelmRelease that copies pre-built static content from the image to the emptyDir. The key is using `advancedMounts` so the init container sees the image's original files (not the empty mount):

```yaml
# In HelmRelease values:
controllers:
  <site>:
    initContainers:
      copy-static:
        image:
          repository: ghcr.io/hayden-agencies/magento2-makergroup
          tag: latest
        command: ["/bin/sh"]
        args:
          - -c
          - |
            echo "[init] Copying static content to shared volume..."
            if [ -d /var/www/html/pub/static ] && [ "$(ls -A /var/www/html/pub/static 2>/dev/null)" ]; then
              cp -a /var/www/html/pub/static/. /shared-static/
              echo "[init] Done ($(find /shared-static -type f | wc -l) files)"
            else
              echo "[init] WARNING: No static content in image — need to add SCD to Dockerfile"
            fi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits: { cpu: "2", memory: 1Gi }

persistence:
  docroot:
    type: emptyDir
    advancedMounts:          # NOT globalMounts — critical!
      <site>:
        copy-static:
          - path: /shared-static    # Different path so image content is visible
        php:
          - path: /var/www/html/pub/static
        nginx:
          - path: /var/www/html/pub/static
```

**Why `advancedMounts`?** With `globalMounts`, the emptyDir mounts at `/var/www/html/pub/static` in the init container too — hiding the image's static files. With `advancedMounts`, the init container mounts at `/shared-static` (the emptyDir) while its `/var/www/html/pub/static` remains the image's original content.

**Pre-requisite:** The Docker image must have static content baked in. Verify:
```bash
docker run --rm --entrypoint /bin/sh ghcr.io/hayden-agencies/magento2-makergroup:latest \
  -c "ls /var/www/html/pub/static/ | head -10"
```
If empty, you need to add `setup:static-content:deploy` to the Dockerfile build phase.

**For immediate manual testing** (lost on pod restart):
```bash
kubectl exec $POD -n business-system -c php -- bash -c '
cd /var/www/html && php bin/magento setup:static-content:deploy en_US -f
'
```

---

### 17. `en_AU` Locale Not Installed in Docker Image

**Symptom:** `setup:static-content:deploy` fails with:
```
en_AU argument has invalid value, run info:language:list for list of available locales
```

**Root Cause:** The Magento Docker image only includes `en_GB` and `en_US` locale packs. The production DB is configured for `en_AU`.

**Fix options:**
- **Option A:** Deploy with available locales: `php bin/magento setup:static-content:deploy en_US -f`
- **Option B:** Install `en_AU` locale in the Docker image build

---

### 18. Cilium ClusterIP Routing Broken on Some Nodes

**Symptom:** MariaDB connection times out even when using the ClusterIP directly:
```
SQLSTATE[HY000] [2002] Operation timed out
```

Pod-to-pod direct IP works, but ClusterIP does not. Affects specific worker nodes (worker2/worker3 in our case). Other services (Redis) work fine via ClusterIP from the same pod. The worker2 pod was persistently crashlooping (1/2 Ready, 11+ restarts) while worker1 was fine.

**Root Cause:** Cilium's eBPF service routing on the affected node doesn't have the correct endpoint map for the MariaDB service. This is a node-level Cilium issue, not a DNS or Magento problem.

**Workaround:** Use pod IPs or ClusterIPs directly to bypass DNS entirely. Get all IPs up front:
```bash
# Get all service ClusterIPs
kubectl get svc -n business-system \
  <site>-redis-master <site>-mariadb-primary \
  <site>-elasticsearch-es-http <site>-rabbitmq \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.clusterIP}{"\n"}{end}'

# If ClusterIP also fails, fall back to pod IP
DB_POD_IP=$(kubectl get pod <site>-mariadb-0 -n business-system -o jsonpath='{.status.podIP}')
```

**Diagnosis:**
```bash
# From the affected pod — ClusterIP fails:
echo quit | nc -w 3 <ClusterIP> 3306    # TCP FAIL

# Direct pod IP works:
echo quit | nc -w 3 <PodIP> 3306        # TCP OK
```

---

### 19. Flux Rollback Loop — HelmRelease Stuck at 418+ Revisions

**Symptom:** `flux get helmrelease auntalma` shows:
```
Helm rollback to previous release business-system/auntalma.v4 ... failed: context deadline exceeded
```

`helm history auntalma -n business-system` shows hundreds of failed revisions, all rolling back to v4 (the pre-migration release).

**Root Cause:** Cascading chicken-and-egg:
1. Flux upgrades the HelmRelease with new env vars/config
2. New pods start but can't pass health checks (Magento needs `setup:upgrade` first, static content is empty, etc.)
3. Helm timeout → Flux rolls back to v4 (old working config... which also doesn't work with imported DB)
4. Repeat every 15 minutes

**Status:** The actual DB migration is done (setup:upgrade, di:compile, indexer:reindex all succeeded). But new pods from Flux can't serve because:
- `pub/static` emptyDir is empty (no init container — Issue #16)
- MariaDB 12 di.xml patch isn't baked in (Issue #2)
- Pods on some workers can't reach MariaDB via ClusterIP (Issue #18)

**Fix plan:**
1. Pin MariaDB to 10.11 OR bake di.xml patch into Docker image
2. Add init container for static content deploy to HelmRelease
3. Fix the `en_AU` locale (add to Docker image or configure stores for `en_US`)
4. Once those are in place, reset Helm release history and let Flux reconcile cleanly

**Cleaning up Helm history** (after fixing all blockers):
```bash
# Option A: Uninstall and let Flux reinstall
flux suspend helmrelease <site> -n business-system
helm uninstall <site> -n business-system
flux resume helmrelease <site> -n business-system
# Flux will do a fresh install with revision 1

# Option B: If you need to keep the release
helm rollback <site> 4 -n business-system   # Roll back to last known good
```

---

### 20. Flux Reverts Manually-Applied ConfigMaps

**Symptom:** You `kubectl apply` a ConfigMap fix (e.g., adding `install.date` to env.php), restart pods, confirm it works — then Flux reconciles and the fix disappears.

**Root Cause:** Flux Kustomization reconciles all manifests from the OCI source every interval. If your change isn't committed and pushed to git (and built into the OCI image), Flux overwrites it with the old version.

**Lesson:** `kubectl apply` is only a temporary hotfix. You MUST commit, push, and wait for the OCI build before Flux will persist the change. If Flux is suspended, the manual apply sticks until you resume.

---

### 21. `kubectl set env` as Emergency Deployment Patch

**Symptom:** Flux is in a rollback loop. Your git changes (short hostnames, MAGE_RUN_CODE) are committed but Flux keeps rolling back to the old Helm release (v4). New pods never get the correct env vars.

**Workaround:** Bypass Helm/Flux entirely by patching the Deployment directly:
```bash
# Suspend Flux first
flux suspend helmrelease <site> -n business-system

# Patch all env vars in one command
HTTPS_PROXY=socks5://127.0.0.1:1234 kubectl set env deployment/<site> -n business-system -c php \
  MAGE_RUN_CODE=base \
  MAGENTO_DB_HOST=<site>-mariadb-primary \
  MAGENTO_SESSION_REDIS_HOST=<site>-redis-master \
  MAGENTO_CACHE_REDIS_HOST=<site>-redis-master \
  MAGENTO_PAGE_CACHE_REDIS_HOST=<site>-redis-master \
  MAGENTO_ES_HOST=<site>-elasticsearch-es-http \
  MAGENTO_AMQP_HOST=<site>-rabbitmq
```

This triggers a new rollout with the correct env vars. Pods restart automatically.

**Important:** This is a manual override — when you resume Flux, it will revert to whatever the HelmRelease specifies.

---

### 22. ConfigMap SubPath Mounts Don't Auto-Update

**Symptom:** You update a ConfigMap (`kubectl apply`), but the running pod still has the old content.

**Root Cause:** ConfigMap volumes mounted via `subPath` are a one-time copy at pod creation. Unlike regular ConfigMap mounts (which update via symlink), subPath mounts never update.

**Fix:** Restart the pod after updating the ConfigMap:
```bash
kubectl rollout restart deployment/<site> -n business-system
```

---

### 23. DNS Flaky Inside `bash -c` Even With Short Hostnames

**Symptom:** `php -r "echo gethostbyname('auntalma-redis-master');"` resolves fine when run directly via `kubectl exec`. But the same hostname fails inside `bash -c '...'`:
```
php_network_getaddresses: getaddrinfo for auntalma-redis-master failed: Try again
```

**Root Cause:** Intermittent DNS resolution failure in Alpine/musl. Rapid sequential DNS lookups from shell subprocesses seem to trigger it. Not 100% reproducible — works sometimes, fails other times.

**Workaround:** For migration commands, resolve all service IPs up front and use them directly:
```bash
# Get IPs before exec-ing into the pod
REDIS_IP=$(kubectl get svc <site>-redis-master -n business-system -o jsonpath='{.spec.clusterIP}')
DB_IP=$(kubectl get pod <site>-mariadb-0 -n business-system -o jsonpath='{.status.podIP}')
ES_IP=$(kubectl get svc <site>-elasticsearch-es-http -n business-system -o jsonpath='{.spec.clusterIP}')
AMQP_IP=$(kubectl get svc <site>-rabbitmq -n business-system -o jsonpath='{.spec.clusterIP}')

# Then use IPs in the exec command
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
..."
```

**Note:** Use pod IP for MariaDB if ClusterIP also fails (Issue #18).

---

## Resolved Blockers

### ES Config (RESOLVED)
The `core_config_data` ES config was updated to point to the local cluster Elasticsearch. Run this for each site after DB import:
```bash
ROOT_PW=$(kubectl get secret <site>-mariadb-superuser -n business-system -o jsonpath='{.data.password}' | base64 -d) && \
kubectl exec <site>-mariadb-0 -n business-system -c mariadb -- \
  mariadb -u root -p"${ROOT_PW}" magento -e "
    UPDATE core_config_data SET value = '<site>-elasticsearch-es-http' WHERE path = 'catalog/search/elasticsearch7_server_hostname';
    UPDATE core_config_data SET value = '9200' WHERE path = 'catalog/search/elasticsearch7_server_port';
    UPDATE core_config_data SET value = '0' WHERE path = 'catalog/search/elasticsearch7_enable_auth';
    UPDATE core_config_data SET value = '' WHERE path LIKE 'catalog/search/elasticsearch7_username';
    UPDATE core_config_data SET value = '' WHERE path LIKE 'catalog/search/elasticsearch7_password';
  "
```

**Important:** Use short service names (not FQDNs) due to Alpine/musl DNS bug (Issue #7).

### setup:upgrade (RESOLVED)
Successfully completed after applying all fixes (di.xml patch, clear generated code, flush Redis, ES config update, short hostnames, log_bin_trust_function_creators). See "Proven Working Workflow" below.

### di:compile (RESOLVED)
Succeeded after adding `install.date` to env.php ConfigMap (Issue #15).

### indexer:reindex (RESOLVED)
All indexers succeeded except Algolia (expected — no API key configured for K8s). Catalog Search indexer required updating ES hostname in `core_config_data` to a ClusterIP (because short hostname DNS failed on the worker node due to Issue #18).

---

## Remaining Blockers

### Blocker: MariaDB 12 di.xml Patch is Temporary
The di.xml version bypass is an in-container patch that is lost on every pod restart. Need to either:
- **Option A:** Pin MariaDB to 10.11 in `mariadb-cluster.yaml` (safest, recommended)
- **Option B:** Bake the patch into the Magento Docker image

### Blocker: `pub/static` EmptyDir Has No Init Container
The emptyDir volume mount hides the Docker image's static content. Without an init container to copy or re-deploy static files, every new pod has an empty `pub/static/` and the storefront is completely broken (404s). See Issue #16.

### Blocker: `en_AU` Locale Missing from Docker Image
Static content deploy fails for `en_AU`. Either add the locale pack to the Docker image build, or reconfigure all stores to use `en_US`. See Issue #17.

### Blocker: Cilium ClusterIP Routing on Some Nodes
Intermittent — MariaDB ClusterIP unreachable from worker3. May resolve itself or need Cilium pod restart on the affected node. See Issue #18.

---

## Proven Working Workflow

This is the all-in-one command that successfully ran `setup:upgrade` on auntalma. Use this as the template for future migrations.

**Important:** Short hostnames can fail intermittently due to DNS flakiness (Issue #23). Resolve all service IPs up front and use them in the env overrides. Use pod IP for MariaDB if ClusterIP fails (Issue #18).

```bash
# 1. Suspend Flux to prevent pod replacement during migration
flux suspend helmrelease <site> -n business-system

# 2. Get pod name and resolve service IPs
POD=$(kubectl get pod -n business-system -l app.kubernetes.io/instance=<site> \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

REDIS_IP=$(kubectl get svc <site>-redis-master -n business-system -o jsonpath='{.spec.clusterIP}')
DB_IP=$(kubectl get pod <site>-mariadb-0 -n business-system -o jsonpath='{.status.podIP}')  # pod IP — ClusterIP unreliable
ES_IP=$(kubectl get svc <site>-elasticsearch-es-http -n business-system -o jsonpath='{.spec.clusterIP}')
AMQP_IP=$(kubectl get svc <site>-rabbitmq -n business-system -o jsonpath='{.spec.clusterIP}')

# 3. All-in-one: patch, flush, setup:upgrade
kubectl exec $POD -n business-system -c php -- bash -c "
# Patch di.xml for MariaDB 12 (skip if MariaDB pinned to 10.11)
sed -i '/MariaDB-(10.2-10.11)/a\\                <item name=\"MariaDB-12\" xsi:type=\"string\">^12\\\.<\\/item>' /var/www/html/vendor/magento/magento2-base/app/etc/di.xml
sed -i '/MariaDB-(10.2-10.11)/a\\                <item name=\"MariaDB-12\" xsi:type=\"string\">^12\\\.<\\/item>' /var/www/html/app/etc/di.xml

# Clear generated code + caches
rm -rf /var/www/html/generated/code/* /var/www/html/generated/metadata/* /var/www/html/var/cache/* /var/www/html/var/di/*

# Flush Redis using IP
php -r \"\\\$r = new Redis(); \\\$r->connect('$REDIS_IP', 6379); \\\$r->select(6); \\\$r->flushDB(); \\\$r->select(1); \\\$r->flushDB();\"

# Override env vars with IPs and run setup:upgrade
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
export MAGENTO_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_PAGE_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_ES_HOST=$ES_IP
export MAGENTO_AMQP_HOST=$AMQP_IP
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento setup:upgrade
"

# 4. Run di:compile (required after setup:upgrade)
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
export MAGENTO_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_PAGE_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_ES_HOST=$ES_IP
export MAGENTO_AMQP_HOST=$AMQP_IP
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento setup:di:compile
"

# 5. Deploy static content (if no init container)
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
export MAGENTO_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_PAGE_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_ES_HOST=$ES_IP
export MAGENTO_AMQP_HOST=$AMQP_IP
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento setup:static-content:deploy en_US -f
"

# 6. Run indexer and cache flush
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
export MAGENTO_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_PAGE_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_ES_HOST=$ES_IP
export MAGENTO_AMQP_HOST=$AMQP_IP
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento indexer:reindex && php bin/magento cache:flush
"

# 7. Resume Flux
flux resume helmrelease <site> -n business-system
```

---

## Complete Migration Checklist

For each Magento site (auntalma, hayden, toemass/dropdrape):

### Pre-requisites (fix BEFORE migration)
- [ ] Pin MariaDB to 10.11 OR bake di.xml patch into Docker image (Issue #2)
- [ ] Add init container to HelmRelease for `pub/static` deployment (Issue #16)
- [ ] Install `en_AU` locale in Docker image OR reconfigure stores for `en_US` (Issue #17)
- [ ] Add `install.date` to env.php ConfigMap (Issue #15)
- [ ] Use short service names in helmrelease env vars (Issue #7)
- [ ] Ensure `log_bin_trust_function_creators=1` in myCnf (Issue #10)

### Pre-flight checks
- [ ] Verify Galera cluster healthy (`kubectl get mariadb -n business-system`)
- [ ] Verify ES, Redis, RabbitMQ running
- [ ] Verify pre-requisites above are all in place

### Database import
- [ ] Dump production DB from VPS
- [ ] Strip `LOCK TABLES` / `UNLOCK TABLES` from dump
- [ ] `kubectl cp` dump into MariaDB pod, import locally
- [ ] Query `store_website` and `store` tables for correct codes
- [ ] Update `MAGE_RUN_CODE` in helmrelease to match DB
- [ ] Update base URLs in `core_config_data` for test domain
- [ ] Update ES config in `core_config_data` to local cluster ES
- [ ] Update crypt key in SOPS secret to match production
- [ ] Flush Redis after any `core_config_data` changes

### Magento setup commands (suspend HelmRelease first!)
- [ ] `flux suspend helmrelease <site> -n business-system`
- [ ] Clear generated code: `rm -rf generated/code/* generated/metadata/* var/cache/* var/di/*`
- [ ] Flush Redis (DB 6 + DB 1)
- [ ] Run `setup:upgrade` (with env overrides if needed)
- [ ] Run `setup:di:compile`
- [ ] Run `setup:static-content:deploy en_US -f` (if no init container yet)
- [ ] Run `indexer:reindex`
- [ ] Run `cache:flush`
- [ ] `flux resume helmrelease <site> -n business-system`

### Media
- [ ] Stream media files from VPS: `ssh ... tar | kubectl exec ... tar`
- [ ] Fix ownership: `chown -R 1000:1000 /var/www/html/pub/media/`

### Verify
- [ ] `curl -I https://<test-domain>/` returns 200
- [ ] Admin panel accessible at `/admin_hayden/`
- [ ] Product pages load with CSS/JS (static content working)
- [ ] Cron jobs not erroring

### auntalma.com.au progress
- [x] Database imported
- [x] Store codes identified (`base` for auntalma, `drop_drape_second_site` for toemass)
- [x] Base URLs updated for test domain
- [x] ES config updated in `core_config_data`
- [x] Crypt key updated in SOPS secret
- [x] `setup:upgrade` completed
- [x] `setup:di:compile` completed
- [x] `indexer:reindex` completed (all except Algolia — no API key)
- [x] `cache:flush` completed
- [ ] Static content deployed (blocked by Issue #16 + #17)
- [ ] Media files transferred (5.2 GB, deferred)
- [ ] Storefront verified
- [ ] Admin panel verified

---

## Key Commands Reference

```bash
# Remote access (when not on local network)
# Requires cloudflared tunnel running: cloudflared access tcp --hostname api.haydenagencies.com.au --url 127.0.0.1:1234 &
# Prefix all kubectl/flux/helm commands with:
HTTPS_PROXY=socks5://127.0.0.1:1234 kubectl ...

# Get root password
ROOT_PW=$(kubectl get secret <site>-mariadb-superuser -n business-system -o jsonpath='{.data.password}' | base64 -d)

# MariaDB CLI (12.1 uses 'mariadb' not 'mysql')
kubectl exec <site>-mariadb-0 -n business-system -c mariadb -- mariadb -u root -p"${ROOT_PW}" magento -e "..."

# Find running app pod
POD=$(kubectl get pod -n business-system -l app.kubernetes.io/instance=<site> --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# Get all service IPs (use when DNS is flaky — Issue #23)
kubectl get svc -n business-system <site>-redis-master <site>-mariadb-primary \
  <site>-elasticsearch-es-http <site>-rabbitmq \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.clusterIP}{"\n"}{end}'

# Flush Redis
kubectl exec $POD -n business-system -c php -- php -r "\$r = new Redis(); \$r->connect('<site>-redis-master', 6379); \$r->select(6); \$r->flushDB(); \$r->select(1); \$r->flushDB();"

# Emergency env var patch (bypasses Flux/Helm — Issue #21)
kubectl set env deployment/<site> -n business-system -c php MAGE_RUN_CODE=base MAGENTO_DB_HOST=<site>-mariadb-primary ...

# Force Flux reconcile
kubectl annotate kustomization cluster -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```
