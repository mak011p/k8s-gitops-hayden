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

**Temporary Fix (lost on pod restart):** Patch `app/etc/di.xml` only (not vendor — vendor is read-only in production mode):
```bash
kubectl exec $POD -n business-system -c php -- \
  sed -i '/MariaDB-(10.2-10.11)/a\                <item name="MariaDB-(12.0-12.4)" xsi:type="string">^12\\.[0-4]\\.</item>' \
  /var/www/html/app/etc/di.xml
```

**CRITICAL:** You MUST also clear generated metadata — the compiled DI config caches version patterns:
```bash
kubectl exec $POD -n business-system -c php -- bash -c \
  "rm -rf /var/www/html/generated/code/* /var/www/html/generated/metadata/* /var/www/html/var/cache/* /var/www/html/var/di/*"
```

Without clearing `generated/metadata/`, the old patterns from the compiled `adminhtml.php`, `frontend.php`, `crontab.php` etc. are used, and MariaDB 12 is still rejected. Using `setup:upgrade --keep-generated` will NOT pick up the di.xml change.

**Permanent Fix — composer module (recommended):**
```bash
# In Docker image build
composer require amadeco/module-db-override
```
This adds MariaDB 10.2-12.4 + MySQL 5.7-8.4 patterns via a proper Magento module.
Source: [amadeco/module-db-override](https://packagist.org/packages/amadeco/module-db-override)

**Alternative:** Pin `mariadb:10.11` in `mariadb-cluster.yaml` and add Renovate ignore rule.

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

### 24. HTTPRoute Backend Service Name Mismatch

**Symptom:** Storefront returns `000` (connection refused). `curl -sk https://auntalma.haydenagencies.com.au/` gets no response at all.

**Root Cause:** HTTPRoute `backendRefs` referenced `auntalma-app` but the bjw-s app-template creates the service as just `auntalma`. Envoy Gateway reported `BackendNotFound`:
```
Failed to process route rule 0 backendRef 0: service business-system/auntalma-app not found.
```

**Fix:** Update `httproute.yaml` and `httproute-admin.yaml`:
```yaml
# Before (broken)
backendRefs:
  - name: auntalma-app
    port: 8080

# After (fixed)
backendRefs:
  - name: auntalma
    port: 8080
```

**How to verify:** Check HTTPRoute status — `ResolvedRefs` should be `True`:
```bash
kubectl get httproute auntalma -n business-system -o jsonpath='{.status.parents[0].conditions}' | python3 -m json.tool
```

---

### 25. Missing external-dns Annotations on HTTPRoute

**Symptom:** DNS doesn't resolve at all for `auntalma.haydenagencies.com.au`. No CNAME record in Cloudflare.

**Root Cause:** External-dns is configured with `--annotation-filter=external-dns.alpha.kubernetes.io/external=true` and `--source=gateway-httproute`. HTTPRoutes without this annotation are ignored. Every other working route (chatwoot, odoo, grafana, etc.) has it.

**Fix:** Add annotations to the HTTPRoute (only needed on the primary route, not the admin route):
```yaml
metadata:
  name: auntalma
  namespace: business-system
  annotations:
    external-dns.alpha.kubernetes.io/external: "true"
    external-dns.alpha.kubernetes.io/target: external.haydenagencies.com.au
```

The `target` annotation tells external-dns to create a CNAME pointing to `external.haydenagencies.com.au` (which is the Cloudflare-proxied endpoint that routes through the cloudflare tunnel to envoy-external).

**Verification:** Check external-dns logs for the record creation:
```bash
kubectl logs -n network-system -l app.kubernetes.io/name=external-dns --tail=10
# Should see: Changing record. action=CREATE record=auntalma.haydenagencies.com.au
```

---

### 26. NetworkPolicy Blocking Envoy Gateway Traffic

**Symptom:** Storefront returns `503` with `upstream connect error or disconnect/reset before headers. reset reason: connection timeout`. Envoy access log shows the request reaching the correct backend IP but timing out after 10 seconds:
```
"GET / HTTP/2" 503 UF 0 91 10001 ... "auntalma.haydenagencies.com.au" "10.244.9.122:8080"
```

Meanwhile, the backend pod is healthy — `health_check.php` returns 200 when tested via `localhost` inside the pod.

**Root Cause:** The `auntalma-app` NetworkPolicy allowed ingress from `envoy-gateway-system` namespace, but the Envoy Gateway proxy pods are actually in the `network-system` namespace:
```yaml
# WRONG — envoy proxy pods are NOT in this namespace
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: envoy-gateway-system
```

**Fix:** Update `networkpolicy.yaml` to target the correct namespace and pods:
```yaml
# CORRECT — match envoy proxy pods in network-system
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: network-system
      podSelector:
        matchLabels:
          gateway.envoyproxy.io/owning-gateway-name: envoy-external
  ports:
    - port: 8080
      protocol: TCP
```

**Key insight:** In this cluster, the Envoy Gateway controller runs in `envoy-gateway-system`, but the data-plane proxy pods (the ones that actually forward traffic) run in `network-system` alongside the Gateway resource. The label `gateway.envoyproxy.io/owning-gateway-name: envoy-external` specifically targets the proxy pods.

**How to debug:** Check which namespace the envoy proxy pods are in:
```bash
kubectl get pods -A -l gateway.envoyproxy.io/owning-gateway-name=envoy-external -o wide
```

---

### 27. NetworkPolicy + Cilium DNS Proxy Breaks Alpine musl libc DNS

**Symptom:** PHP-FPM health check times out → nginx container enters CrashLoopBackOff (139+ restarts). Magento can't connect to Redis/MariaDB:
```
php_network_getaddresses: getaddrinfo for auntalma-redis-master failed: Try again
```

DNS works via `nslookup` and PHP's `dns_get_record()`, but fails via `gethostbyname()` and `getaddrinfo()` (used by PDO, fsockopen, Redis).

**Root Cause:** Three-way incompatibility:
1. **Alpine musl libc** sends A and AAAA DNS queries simultaneously on the same UDP socket
2. **Cilium transparent DNS proxy** (`enable-l7-proxy: true`, `dnsproxy-enable-transparent-mode: true`) intercepts DNS when ANY NetworkPolicy (K8s or Cilium) is applied to a pod
3. The proxy re-orders or delays responses, causing musl's parallel query logic to fail intermittently

**Key findings:**
- Without any NetworkPolicy: DNS works 100% reliably
- With K8s NetworkPolicy (even ingress-only, no egress rules): DNS fails intermittently
- With CiliumNetworkPolicy (with or without `dns` L7 rules): DNS also fails
- Non-Alpine pods (e.g., Chatwoot/Ruby) with the same NetworkPolicy pattern work fine
- TCP DNS to kube-dns ClusterIP is blocked even when explicitly allowed (Cilium can't match service VIPs to pod selectors after DNAT)

**Tested and failed:**
- K8s NetworkPolicy with pod selector for kube-dns (original)
- K8s NetworkPolicy with ipBlock for kube-dns ClusterIP
- K8s NetworkPolicy with port-only DNS rule (no destination)
- K8s NetworkPolicy with ingress-only (no egress policyType)
- CiliumNetworkPolicy with `dns: [{matchPattern: "*"}]` L7 rules
- CiliumNetworkPolicy without L7 rules

**Current fix:** NetworkPolicy removed entirely for auntalma pods. All other egress restrictions are removed.

**UPDATE:** DNS fails intermittently even WITHOUT NetworkPolicy (~60% failure rate on `gethostbyname`/`getaddrinfo`). Cilium 1.18.6 has `dnsproxy-enable-transparent-mode: true` by default, meaning the DNS proxy intercepts ALL DNS traffic regardless of whether policies exist.

**Permanent fix — Cilium config change (recommended):**

Add to `kubernetes/apps/base/kube-system/cilium/app/values.yaml`:
```yaml
dnsProxy:
  dnsRejectResponseCode: nameError
```

This changes Cilium from returning `REFUSED` (musl aborts on this) to `NXDOMAIN` (musl handles correctly and continues searching). Cluster-wide fix, no image changes needed.

Source: [Cilium DNS + glibc resolver](https://farcaller.net/2024/cilium-dns-policies-and-the-glibc-resolver/), [cilium/cilium#33144](https://github.com/cilium/cilium/issues/33144)

**Other options (if Cilium fix insufficient):**
- **Option A:** Switch from Alpine to Debian-based PHP image (glibc handles DNS correctly)
- **Option B:** Add `dnsConfig` to pod spec — note: `single-request-reopen` is glibc-only, musl only supports `ndots`, `timeout`, `attempts`
- **Option C:** Use `hostAliases` in pod spec to bypass DNS entirely (fragile — ClusterIPs can change)

---

### 28. K8s NetworkPolicy + Cilium = Broken Pod Networking on Some Nodes

**Symptom:** Pods on worker2/worker3 have **zero network connectivity** — can't ping kube-dns ClusterIP, can't reach any pod IP, can't resolve DNS. But worker1 pods with the same spec work fine. Cilium endpoint shows `ready`. Plain Alpine pods without NetworkPolicy work fine on the same nodes.

**Root Cause:** Kubernetes NetworkPolicy (even ingress-only with NO egress rules) triggers Cilium to attach eBPF programs for policy enforcement. On some nodes, these programs break the pod's entire datapath — not just DNS, but ALL traffic. The issue is node-specific and non-deterministic.

**Key findings:**
- Removing the NetworkPolicy entirely restores networking immediately
- The issue is NOT related to egress rules — even `policyTypes: [Ingress]` with no egress section triggers it
- Restarting the cilium agent on the affected node does NOT fix it
- Deleting and recreating the pod does NOT fix it (new pod on same node also broken)
- Plain pods (no NetworkPolicy matching them) work fine on the same nodes
- This is likely a Cilium bug with `datapathMode: netkit` (eBPF-based datapath)

**Current fix:** NetworkPolicy changed to ingress-only (egress enforcement removed). But on some nodes, even this triggers the issue.

**Workaround for affected deployments:**
1. Scale to 1 replica pinned to a working node
2. Or remove NetworkPolicy entirely until Cilium fix is available

**Related:** Issue #27 (DNS-specific symptoms were actually this broader networking issue)

---

### 29. `kubectl set env` Triggers Rollout — Loses All In-Container Patches

**Symptom:** After using `kubectl set env` to add IP-based env vars (bypassing DNS), all pages go 500 with "Unable to retrieve deployment version of static files" or "The configuration file has changed."

**Root Cause:** `kubectl set env` modifies the deployment spec, triggering a pod rollout. New pods start from the original Docker image, losing:
- di.xml MariaDB 12 patch
- Compiled DI code (`generated/metadata/` and `generated/code/`)
- Static content deployed to emptyDir
- Any `app:config:import` state

**Lesson:** NEVER use `kubectl set env` during migration. Instead, pass env var overrides via `kubectl exec ... bash -c "export VAR=val && php bin/magento ..."`. This runs commands with overridden env vars WITHOUT modifying the deployment spec or triggering a rollout.

**If you already did it:** You need to re-run the full Magento post-migration sequence (di.xml patch, clear generated, setup:upgrade, di:compile, static-content:deploy, indexer:reindex, cache:flush) on the new pods.

---

### 30. `app:config:import` Required After Config Changes

**Symptom:** All pages return 500 with:
```
The configuration file has changed. Run the "app:config:import" or the "setup:upgrade" command to synchronize the configuration.
```

**Root Cause:** Magento's `ConfigChangeDetector` compares a hash of `config.php` + `env.php` against a stored hash in the DB. If they differ (e.g., after env var changes, ConfigMap updates, or import operations), all requests are blocked.

**Fix:**
```bash
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento app:config:import
```

**Important:** This command itself can trigger the static content version error (Issue #16) because it updates the config version hash. After running it, you may need to redeploy static content.

---

### 31. env.php Uses Non-Obvious Env Var Names

**Symptom:** Setting `MAGENTO_ELASTICSEARCH_HOST` or `MAGENTO_REDIS_HOST` has no effect — Magento still uses default `localhost`.

**Root Cause:** The env.php ConfigMap reads specific env var names that don't match intuitive guesses:

| Service | Correct Env Var | Wrong Guess |
|---------|----------------|-------------|
| Elasticsearch | `MAGENTO_ES_HOST` | `MAGENTO_ELASTICSEARCH_HOST` |
| Session Redis | `MAGENTO_SESSION_REDIS_HOST` | `MAGENTO_REDIS_HOST` |
| Cache Redis | `MAGENTO_CACHE_REDIS_HOST` | `MAGENTO_REDIS_HOST` |
| Page Cache Redis | `MAGENTO_PAGE_CACHE_REDIS_HOST` | `MAGENTO_REDIS_HOST` |

**Lesson:** Always check `configmap-env-php.yaml` for the exact `getenv()` calls before setting env vars. Each Redis instance (session, cache, page cache) has its own host/port/db env vars.

---

### 32. Homepage 404 — Multiple Overlapping Causes

**Symptom:** Homepage `/` returns static 404 (659 bytes) while all other pages work (customer login 200/83KB, search 200, contact 200, cart 200).

**Root Cause (updated Feb 11):** This was misdiagnosed as a pure ES PHP client issue. Investigation revealed **three overlapping causes**, each producing the same 404 symptom:

1. **`ConfigChangeDetector` blocking all requests** (primary cause): After Helm release history was nuked and Flux did a fresh install, the new pods had a DB schema mismatch (`setup:db:status` → "Declarative Schema is not up to date"). Magento's `ConfigChangeDetector` intercepts ALL requests and throws `LocalizedException` before any routing occurs. The error handler renders the static 404 page. The exception log deduplicates identical exceptions, so subsequent hits don't log new entries — making it look like "no error is thrown."

2. **ES PHP client intermittent ClusterIP timeouts** (secondary cause): Even with DNS working, PHP's `curl_init()` to the ES ClusterIP intermittently times out (10s). The ES `elasticsearch/elasticsearch` library built on top of curl also fails. However, the same ClusterIP works via `curl` CLI from the same pod — the issue is specific to PHP's curl extension/socket handling on Alpine. Setting the ClusterIP directly in `core_config_data` AND env var overrides together was needed to bypass this (see Issue #38).

3. **`setup:upgrade` wipes static content** (tertiary cause): After running `setup:upgrade` to fix cause #1, it clears `pub/static/` (including `deployed_version.txt` copied by the init container), breaking ALL pages with "Unable to retrieve deployment version of static files" (see Issue #37).

**Diagnosis flow:**
```
Initial symptom: homepage 404 (659 bytes)
├─ CMS config? → No: /home returns 200, cms_home_page=home, page_id 2 exists
├─ ES PHP client? → Yes, partially: exception log shows "No alive nodes"
│   └─ But: DNS works (gethostbyname resolves), curl works → PHP curl timeout issue
├─ ConfigChangeDetector? → YES: setup:db:status shows schema out of date
│   └─ Fix: setup:upgrade + di:compile + app:config:import
└─ After fix: setup:upgrade wipes pub/static → need SCD or pod restart
```

**Key lesson:** When Magento returns a static 404 page (from `pub/errors/`), check `var/report/` for error details — the exception log may be deduplicating. The `ConfigChangeDetector` error is silent after the first log entry and blocks ALL routes before any CMS/catalog logic runs.

---

### 33. Helm Release History Poisoning

**Symptom:** HelmRelease stuck in upgrade/rollback loop. `helm history` shows 400+ failed revisions, all rolling back to the same old revision. New upgrades fail with `context deadline exceeded` before pods even start.

**Root Cause:** Each failed upgrade + automatic rollback creates 2 Helm release secrets. After hundreds of cycles, Helm spends most of its timeout just loading release history. The release never cleans up because every attempt fails.

**Fix:** Delete all Helm release secrets to force a fresh install:
```bash
# Suspend Flux first
flux suspend helmrelease <site> -n business-system

# Delete ALL helm release history (forces fresh install on next reconcile)
kubectl delete secrets -n business-system -l owner=helm,name=<site>

# Resume Flux — will do a fresh install (revision 1)
flux resume helmrelease <site> -n business-system
```

**Warning:** This is a nuclear option — Helm loses all rollback history. Only use when the release is already broken beyond repair. Make sure your HelmRelease values are correct before resuming.

---

### 34. HelmRelease Upgrade Timeout Must Be 10m+ for Magento

**Symptom:** HelmRelease upgrade completes successfully (pods reach 2/2 Ready) but Helm still rolls back. `helm history` shows the upgrade as `failed` despite pods being healthy.

**Root Cause:** Magento pods have long `initialDelaySeconds` on probes (120s for liveness, 30s for readiness). The default Helm upgrade timeout is 5 minutes. With init containers (static-copy ~30s) + readiness delay (30s) + actual startup time, pods can take 3-4 minutes to become Ready. On slower nodes or with image pulls, this exceeds 5 minutes. Helm marks the upgrade as failed and rolls back.

**Fix:** Add explicit upgrade timeout to the HelmRelease:
```yaml
spec:
  upgrade:
    timeout: 10m
```

**Note:** This timeout covers the entire upgrade operation including waiting for all pods to become Ready, not just the Helm template rendering. For Magento with 2+ replicas, 10 minutes is a safe buffer.

---

### 35. `setup:upgrade` Fails with ES but `app:config:import` Works

**Symptom:** `setup:upgrade` fails with:
```
No alive nodes found in your cluster
```
Even though `curl http://auntalma-elasticsearch-es-http:9200` returns a healthy response from the same pod.

**Root Cause:** Magento's `setup:upgrade` validates Elasticsearch connectivity using the PHP `elasticsearch/elasticsearch` client library, which performs its own DNS resolution and connection pooling. The PHP ES client may fail where raw HTTP succeeds due to:
- musl DNS flakiness in the PHP runtime (different socket behavior than curl)
- Connection timeout defaults in the PHP ES client
- The client performing a "sniff" operation that resolves to unreachable node IPs

**Workaround:** Use `app:config:import` instead of `setup:upgrade` when you only need to sync the config version hash (i.e., after env.php or config.php changes). `app:config:import` doesn't validate ES connectivity:
```bash
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento app:config:import
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento cache:flush
```

**When to use which:**
- `setup:upgrade`: Required after DB schema changes, module install/upgrade, or major version bumps
- `app:config:import`: Sufficient when only config files (env.php, config.php) have changed — syncs the config version hash in the DB

---

### 36. HPA MinReplicas Overrides Manual `kubectl scale`

**Symptom:** You scale the deployment to 1 replica with `kubectl scale --replicas=1`, but within seconds it scales back up to 2.

**Root Cause:** The HorizontalPodAutoscaler (HPA) has `minReplicas: 2` configured. HPA continuously reconciles and overrides any manual scaling that drops below its minimum.

**Fix:** Patch the HPA's minReplicas to allow single-replica operation:
```bash
kubectl patch hpa <site> -n business-system --type='json' \
  -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 1}]'
```

**Important:** Remember to restore minReplicas when multi-node operation is fixed. This is a temporary workaround for the Cilium + NetworkPolicy issue (Issue #28) that prevents pods on worker2/worker3 from having network connectivity.

---

### 37. `setup:upgrade` Wipes `pub/static` — Init Container Content Lost

**Symptom:** After running `setup:upgrade`, ALL pages break with "Unable to retrieve deployment version of static files" or render without CSS/JS.

**Root Cause:** `setup:upgrade` runs file system cleanup that deletes:
```
/var/www/html/pub/static/adminhtml
/var/www/html/pub/static/deployed_version.txt
/var/www/html/pub/static/frontend
/var/www/html/var/view_preprocessed/pub
```

The init container (`static-copy`) copies baked-in static files at pod startup, but `setup:upgrade` wipes them. Since `pub/static` is an emptyDir, there's no image content to fall back to.

**Fix:** After running `setup:upgrade`, you MUST either:
- **Option A:** Restart the pod (triggers init container to re-copy static files)
- **Option B:** Run `setup:static-content:deploy` manually:
```bash
kubectl exec $POD -n business-system -c php -- bash -c "
cd /var/www/html && php bin/magento setup:static-content:deploy en_US en_AU -f
"
```

**Important:** This means the full post-migration sequence is: `setup:upgrade` → `di:compile` → pod restart (or SCD) → `app:config:import` → `cache:flush`. The pod restart is needed between `di:compile` and `app:config:import` to restore static content from the init container.

---

### 38. ES PHP Client ClusterIP Timeouts — `core_config_data` Overrides env.php

**Symptom:** `setup:upgrade` fails with "No alive nodes found in your cluster" even when:
- DNS resolves correctly (`gethostbyname` returns correct IP)
- `curl` to ES service works from the same pod
- env var `MAGENTO_ES_HOST` is set to the ClusterIP

**Root Cause:** Two issues compound:

1. **`core_config_data` overrides `system.default` in env.php** for already-configured stores. Setting `MAGENTO_ES_HOST` env var only populates `system.default.catalog.search.elasticsearch7_server_hostname` in env.php. But if the DB already has `catalog/search/elasticsearch7_server_hostname` in `core_config_data`, the DB value takes precedence at runtime.

2. **PHP curl to ClusterIP intermittently times out on Alpine**: Raw `curl_init()` to the ES ClusterIP from PHP times out (10s) even when CLI `curl` works. The ES PHP client library (`elasticsearch/elasticsearch`) uses PHP curl internally. The issue is intermittent and may be related to musl's socket handling or Cilium's eBPF datapath.

**Fix:** Update BOTH the env var AND the `core_config_data`:
```bash
# 1. Set ClusterIP in core_config_data
ES_IP=$(kubectl get svc <site>-elasticsearch-es-http -n business-system -o jsonpath='{.spec.clusterIP}')
kubectl exec <site>-mariadb-0 -n business-system -c mariadb -- bash -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" magento -e "
    UPDATE core_config_data SET value = '"'"''"$ES_IP"''"'"' WHERE path = '"'"'catalog/search/elasticsearch7_server_hostname'"'"';
  "'

# 2. Flush Redis after DB config change
kubectl exec $POD -n business-system -c php -- php -r "
\$r = new Redis(); \$r->connect('$REDIS_IP', 6379);
\$r->select(6); \$r->flushDB(); \$r->select(1); \$r->flushDB();"

# 3. Pass env var override in setup:upgrade command
export MAGENTO_ES_HOST=$ES_IP
```

**Note:** After resolving ES connectivity, revert `core_config_data` back to the DNS name for ongoing runtime use — the ClusterIP can change if the service is recreated.

---

### 39. Homepage 404 — nginx `try_files $uri/` With Split Containers

**Symptom:** Homepage `/` returns a static 404 (659 bytes from `pub/errors/default/`). ALL other Magento routes work (`/customer/account/login/` 200, `/catalogsearch/result/?q=test` 200, `/contact/` 200, `/home` 200). No Magento error report is generated.

**Root Cause:** nginx error log reveals:
```
directory index of "/var/www/html/pub/" is forbidden
```

In this bjw-s app-template architecture, nginx and PHP-FPM are separate containers. The nginx container is a plain `nginx:alpine` image that does NOT contain the Magento codebase. Only `pub/static` and `pub/media` are shared via emptyDir/PVC mounts. Crucially, `pub/index.php` does NOT exist in the nginx container's filesystem.

The standard Magento nginx config has:
```nginx
location / {
    try_files $uri $uri/ /index.php$is_args$args;
}
```

For `GET /`, nginx evaluates `try_files` left to right:
1. `$uri` → `/` → checks `/var/www/html/pub/` as a file → it's a directory, skip
2. `$uri/` → `/` → checks `/var/www/html/pub/` as a directory → **exists** → nginx tries `index index.php` directive → `pub/index.php` doesn't exist on nginx filesystem → **403 forbidden** → `error_page 404 403 = /errors/404.php` → static 404
3. `/index.php$is_args$args` → **never reached**

Other URLs like `/customer/account/login/` work because that directory doesn't exist on the nginx filesystem, so step 2 fails and step 3 (the PHP fallback) is reached.

**Fix:** Remove `$uri/` from `try_files` in the nginx ConfigMap:
```nginx
location / {
    try_files $uri /index.php$is_args$args;
}
```

This is safe because:
- Static files (`pub/static/`, `pub/media/`) are served by their own location blocks
- All other requests should go to PHP-FPM via `index.php`
- Directory listing is never needed in a Magento deployment

**Key lesson:** Standard Magento nginx configs assume nginx and PHP share the same filesystem. In Kubernetes split-container deployments (separate nginx + PHP-FPM containers), `try_files $uri/` breaks for the root URL because `pub/` exists as a directory but `pub/index.php` doesn't. Any Magento nginx config for split containers must remove `$uri/` from `try_files`.

---

### 40. `app:config:import` Must Run With Pod's Native Env Vars

**Symptom:** After running `app:config:import` with IP-overridden env vars (`export MAGENTO_DB_HOST=10.x.x.x && php bin/magento app:config:import`), it reports "Nothing to import." But the web process (PHP-FPM) still shows the `ConfigChangeDetector` error: "The configuration file has changed."

**Root Cause:** Magento's `ConfigChangeDetector` computes a hash of the **evaluated** configuration — not the raw file content, but the resolved array including all `getenv()` values. When you run `app:config:import` with overridden env vars, the stored hash reflects those IPs. But PHP-FPM uses the pod's actual env vars (DNS hostnames), producing a different hash → mismatch → all requests blocked.

**Fix:** Run `app:config:import` via plain `kubectl exec` WITHOUT any `bash -c "export ... &&"` wrappers:
```bash
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento app:config:import
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento cache:flush
```

This uses the pod's native env vars, producing a hash that matches what PHP-FPM computes at runtime.

**Important:** Use IP overrides only for `setup:upgrade` and `setup:di:compile` (which need reliable ES/DB connections). Always run `app:config:import` and `cache:flush` with native env vars as the FINAL step.

**Updated workflow order:**
1. `setup:upgrade` (with IP overrides — ES connectivity required)
2. `setup:di:compile` (with IP overrides)
3. Pod restart (restores `pub/static` via init container)
4. `app:config:import` (**native env vars** — no overrides)
5. `cache:flush` (**native env vars**)
6. `indexer:reindex` (with IP overrides if needed for ES)

---

### 41. Flux Fresh Install Recreates Deleted NetworkPolicy

**Symptom:** After deleting the NetworkPolicy to work around Issue #28, Flux does a fresh install (after Helm history reset) and the NetworkPolicy comes back, breaking networking on worker2/worker3 again.

**Root Cause:** The NetworkPolicy is part of the HelmRelease template. Any Flux reconciliation (install, upgrade) recreates it. `kubectl delete` is only a temporary fix that lasts until the next reconcile.

**Workaround:** After each Flux reconcile, immediately delete the NetworkPolicy:
```bash
kubectl delete networkpolicy auntalma-app -n business-system
```

**Permanent fix needed:** Either disable the NetworkPolicy in HelmRelease values, or resolve the Cilium + K8s NetworkPolicy compatibility issue (Issue #28).

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
- **Option A (preferred):** Install `amadeco/module-db-override` in the Docker image build — adds MariaDB 10.2-12.4 + MySQL 5.7-8.4 support via a proper Magento module
- **Option B:** Bake the `sed` patch into a Dockerfile `RUN` step
- **~~Option C:~~** ~~Pin MariaDB to 10.11~~ — NOT viable, Galera cluster already has 12.1 data files, can't downgrade in-place without data loss

### ~~Blocker~~ RESOLVED: `en_AU` Locale (Issue #17)
Runtime `setup:static-content:deploy en_AU` fails (no locale pack installed). However, the Docker image has `en_AU` static content **baked in at build time**. The init container copies it successfully (13,945 files including `frontend/Rival/auntalma/en_AU/`). This is only a blocker if you need to regenerate static content at runtime.

### Blocker: K8s NetworkPolicy + Cilium Breaks Pod Networking on Some Nodes
Any K8s NetworkPolicy (even ingress-only with NO egress rules) triggers Cilium eBPF policy enforcement which breaks the pod's entire datapath on worker2/worker3 — not just DNS, but ALL traffic. Pods on worker1 with identical config work fine. Likely related to `datapathMode: netkit`. See Issue #28.

**Current state:** Auntalma running 1 replica on worker1 only. HPA minReplicas set to 1 temporarily. Cannot scale to multi-node until this is resolved. Options:
- Remove NetworkPolicy entirely (current workaround)
- Switch to CiliumNetworkPolicy (may have same issue)
- Test with `datapathMode: veth` (Cilium restart, brief network blip)
- Wait for Cilium fix / upgrade

### RESOLVED: `pub/static` EmptyDir Init Container (Issue #16)
Init container `static-copy` added to auntalma HelmRelease. Copies baked-in static files from image to emptyDir using `advancedMounts`. Committed: `9834473f6`. Verified: pod 2/2 Running, 13,945 static files copied including en_AU locale. `deployed_version.txt` present.

### RESOLVED: Cilium DNS Proxy Breaks Alpine musl libc (Issue #27)
Applied `dnsProxy.dnsRejectResponseCode: nameError` to Cilium values.yaml. Changes REFUSED→NXDOMAIN for blocked DNS queries. Committed: `b642d7f5d`. Verified: 10/10 `gethostbyname()` resolutions from Magento PHP pod (musl libc). DNS is no longer a blocker — the remaining ES "No alive nodes" issue on homepage is in the PHP ES client library, not DNS.

### RESOLVED: Cilium ClusterIP Routing on Some Nodes (Issue #18)
Likely related to the broader NetworkPolicy + Cilium eBPF issue (Issue #28). With NetworkPolicy removed and single-replica on worker1, ClusterIP routing works fine.

### RESOLVED: Networking (Issues #24, #25, #26)
Three networking issues prevented external traffic from reaching auntalma pods:
1. **HTTPRoute** referenced wrong service name `auntalma-app` → fixed to `auntalma`
2. **external-dns** annotations missing → DNS record was never created
3. **NetworkPolicy** allowed ingress from `envoy-gateway-system` but proxies are in `network-system`

All three fixed and applied. Storefront now responds through Cloudflare tunnel.

### RESOLVED: Homepage 404 — nginx `try_files` (Issue #39)
Root URL `/` returned static 404 while all other Magento routes worked. Caused by `try_files $uri $uri/ /index.php$is_args$args` — the `$uri/` check matches the `pub/` directory on nginx's filesystem, but `pub/index.php` doesn't exist in the nginx container (split-container architecture). Fixed by removing `$uri/` → `try_files $uri /index.php$is_args$args`.

### RESOLVED: `app:config:import` Hash Mismatch (Issue #40)
Running `app:config:import` with IP-overridden env vars stores a config hash that doesn't match what PHP-FPM computes with the pod's native DNS-based env vars. Fix: always run `app:config:import` and `cache:flush` without env overrides as the final step.

---

## Proven Working Workflow

This is the all-in-one command that successfully ran `setup:upgrade` on auntalma. Use this as the template for future migrations.

**Note:** After applying the Cilium DNS fix (Issue #27, commit `b642d7f5d`), short hostnames resolve reliably for most operations. However, `setup:upgrade` ES validation still intermittently fails with DNS hostnames — **IP overrides for ES are required** (see Issue #38). You must also update `core_config_data` to use the ES ClusterIP, since DB config overrides env.php.

**WARNING:** `setup:upgrade` wipes `pub/static/` (Issue #37). After the full sequence, either restart the pod (init container re-copies static files) or run `setup:static-content:deploy` manually.

**CRITICAL:** Pass env overrides via `export` inside `kubectl exec ... bash -c "..."`. NEVER use `kubectl set env` — it modifies the deployment spec and triggers a rollout, destroying all in-container patches (Issue #29).

**CRITICAL:** `app:config:import` and `cache:flush` must run with the pod's **native env vars** (no overrides). The config hash must match what PHP-FPM computes at runtime. Use IP overrides only for `setup:upgrade`, `di:compile`, and `indexer:reindex`. (Issue #40)

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

# 3. Update ES hostname in core_config_data to ClusterIP (DB config overrides env.php — Issue #38)
kubectl exec <site>-mariadb-0 -n business-system -c mariadb -- bash -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" magento -e "
    UPDATE core_config_data SET value = '"'"''"$ES_IP"''"'"' WHERE path = '"'"'catalog/search/elasticsearch7_server_hostname'"'"';
  "'

# 4. All-in-one: patch, flush, setup:upgrade
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

# 5. Run di:compile (required after setup:upgrade)
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

# 6. Restore static content (setup:upgrade wipes pub/static — Issue #37)
# Option A: Restart pod to trigger init container (recommended)
kubectl delete pod $POD -n business-system
# Wait for new pod to be ready
kubectl wait --for=condition=Ready pod -n business-system -l app.kubernetes.io/instance=<site> --timeout=5m
# Re-resolve pod name after restart
POD=$(kubectl get pod -n business-system -l app.kubernetes.io/instance=<site> \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# Option B: OR deploy static content manually (slower, but no pod restart)
# kubectl exec $POD -n business-system -c php -- bash -c "
# cd /var/www/html && php bin/magento setup:static-content:deploy en_US en_AU -f
# "

# 7. Sync config hash and flush caches
# CRITICAL: Do NOT use env overrides here! The config hash must match what PHP-FPM
# computes at runtime using the pod's native env vars. (Issue #40)
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento app:config:import
kubectl exec $POD -n business-system -c php -- php /var/www/html/bin/magento cache:flush

# 8. Run indexer
kubectl exec $POD -n business-system -c php -- bash -c "
export MAGENTO_DB_HOST=$DB_IP
export MAGENTO_SESSION_REDIS_HOST=$REDIS_IP
export MAGENTO_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_PAGE_CACHE_REDIS_HOST=$REDIS_IP
export MAGENTO_ES_HOST=$ES_IP
export MAGENTO_AMQP_HOST=$AMQP_IP
export MAGE_RUN_CODE=base
cd /var/www/html && php bin/magento indexer:reindex
"

# 9. Revert ES core_config_data back to DNS name (ClusterIP may change on service recreation)
kubectl exec <site>-mariadb-0 -n business-system -c mariadb -- bash -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" magento -e "
    UPDATE core_config_data SET value = '"'"'<site>-elasticsearch-es-http'"'"' WHERE path = '"'"'catalog/search/elasticsearch7_server_hostname'"'"';
  "'
kubectl exec $POD -n business-system -c php -- bash -c "
php -r \"\\\$r = new Redis(); \\\$r->connect('$REDIS_IP', 6379); \\\$r->select(6); \\\$r->flushDB(); \\\$r->select(1); \\\$r->flushDB();\"
"

# 10. Resume Flux
flux resume helmrelease <site> -n business-system
```

---

## Complete Migration Checklist

For each Magento site (auntalma, hayden, toemass/dropdrape):

### Pre-requisites (fix BEFORE migration)
- [x] Fix Cilium DNS proxy for musl compat — add `dnsProxy.dnsRejectResponseCode: nameError` to Cilium values (Issue #27) — **DONE** commit `b642d7f5d`
- [x] Add init container to HelmRelease for `pub/static` deployment (Issue #16) — **DONE** commit `9834473f6`
- [x] Set HelmRelease upgrade timeout to 10m (Issue #34) — **DONE** commit `075024db0`
- [ ] Install `amadeco/module-db-override` in Docker image OR bake di.xml patch into Dockerfile (Issue #2) — cannot pin MariaDB to 10.11, Galera already has 12.1 data
- [x] ~~Install `en_AU` locale in Docker image~~ — image has en_AU baked in, init container copies it (Issue #17)
- [ ] Add `install.date` to env.php ConfigMap (Issue #15)
- [ ] Use short service names in helmrelease env vars (Issue #7)
- [ ] Ensure `log_bin_trust_function_creators=1` in myCnf (Issue #10)
- [ ] Fix HTTPRoute `backendRefs` to match actual service name (Issue #24)
- [ ] Add external-dns annotations to HTTPRoute (Issue #25)
- [ ] Fix NetworkPolicy to allow traffic from `network-system` envoy pods (Issue #26)
- [ ] Verify env var names match `configmap-env-php.yaml` `getenv()` calls (Issue #31)
- [ ] Resolve Cilium + K8s NetworkPolicy multi-node networking issue (Issue #28) — or remove NetworkPolicy
- [ ] Fix nginx `try_files` for split-container architecture — remove `$uri/` (Issue #39)

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
- [ ] Delete NetworkPolicy if present (Issue #41 — Flux recreates it on install)
- [ ] Update ES `core_config_data` to ClusterIP (Issue #38 — DB config overrides env.php)
- [ ] Clear generated code: `rm -rf generated/code/* generated/metadata/* var/cache/* var/di/*`
- [ ] Flush Redis (DB 6 + DB 1)
- [ ] Run `setup:upgrade` (with IP env overrides — especially `MAGENTO_ES_HOST`)
- [ ] Run `setup:di:compile` (with IP env overrides)
- [ ] Restore `pub/static` — restart pod (init container re-copies) OR run SCD (Issue #37)
- [ ] Run `app:config:import` (**native env vars — NO overrides** — Issue #40)
- [ ] Run `cache:flush` (**native env vars — NO overrides**)
- [ ] Run `indexer:reindex` (with IP env overrides if needed for ES)
- [ ] Revert ES `core_config_data` back to DNS name + flush Redis
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
- [x] HTTPRoute backend name fixed (`auntalma-app` → `auntalma`) (Issue #24)
- [x] external-dns annotations added to HTTPRoute (Issue #25)
- [x] NetworkPolicy fixed for envoy-external in `network-system` (Issue #26)
- [x] NetworkPolicy egress removed — Cilium eBPF + K8s NetworkPolicy incompatible (Issue #27, #28)
- [x] Cilium DNS proxy fix applied (`dnsRejectResponseCode: nameError`) — commit `b642d7f5d`
- [x] Init container `static-copy` added for `pub/static` — commit `9834473f6`
- [x] HelmRelease upgrade timeout increased to 10m — commit `075024db0`
- [x] Helm release history reset (deleted poisoned secrets, fresh install)
- [x] Static content deployed (`setup:static-content:deploy en_US en_GB -f` — all 16 themes)
- [x] di.xml MariaDB 12 patch applied + generated code cleared
- [x] `app:config:import` + `cache:flush` completed on current pod
- [x] Storefront responding (200 on `/customer/account/login/`)
- [x] Admin panel redirects to OAuth (302 → Dex, working correctly)
- [x] Cilium DNS fix verified — 10/10 musl `gethostbyname()` resolutions from Magento pod
- [x] ES `core_config_data` hostname reverted from ClusterIP to DNS name (DNS now reliable)
- [x] Init container verified — 13,945 static files copied, pod 2/2 Running, `deployed_version.txt` present
- [x] `en_AU` locale confirmed baked into Docker image (init container copies it)
- [x] Homepage 404 root cause identified — `ConfigChangeDetector` + stale schema (Issue #32 updated)
- [x] `setup:upgrade` re-run on fresh pod (v1 install) with IP overrides for ES (Issue #38)
- [x] `setup:di:compile` completed on fresh pod
- [x] ES `core_config_data` temporarily set to ClusterIP for `setup:upgrade` (Issue #38)
- [x] `pub/static` restored via pod restart (init container re-copied 13,943 files + `deployed_version.txt`)
- [x] `app:config:import` run with **native env vars** (Issue #40 — IP overrides cause hash mismatch)
- [x] `cache:flush` completed with native env vars
- [x] `indexer:reindex` completed on fresh pod (all succeeded except Algolia lock — expected)
- [x] ES `core_config_data` reverted from ClusterIP back to DNS name + Redis flushed
- [x] NetworkPolicy deleted (Flux fresh install recreated it — Issue #41)
- [x] Storefront pages working: `/customer/account/login/` 200, `/catalogsearch/result/?q=test` 200, `/contact/` 200, `/home` 200
- [x] Homepage 404 root cause identified — nginx `try_files $uri/` with split containers (Issue #39)
- [x] nginx ConfigMap fix applied — removed `$uri/` from `try_files` (Issue #39)
- [x] Homepage `/` returns 200 (82KB) — nginx `try_files` fix confirmed working
- **Current state (11 Feb 2026):** HelmRelease suspended, 1 replica on worker1 (2/2 Running, HPA minReplicas=1). All pages working: `/` 200, `/customer/account/login/` 200, `/catalogsearch/` 200, `/contact/` 200, `/admin_hayden/` 302→OAuth. ES config on DNS name. NetworkPolicy deleted.
- [ ] Commit nginx `try_files` fix to git
- [ ] Multi-node scaling blocked by Cilium + NetworkPolicy issue (Issue #28)
- [ ] Media files transferred (5.2 GB, deferred)
- [ ] Cron jobs verified
- [ ] Go-live (DNS cutover to production domain)

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
