# Magento-Odoo Integration (Staging) - Living Guide

**Keep this file as concise as possible.**

This document captures practical knowledge for testing and operating the staging Magento-Odoo integration. It is **not a checklist** — it is a living guide that should be updated as new lessons are learned. Future agents should read this before working on the integration, and **append findings** when they discover something new.

---

## How to Use This Guide

- **Read first, act second.** Skim the gotchas and environment sections before running commands.
- **Update when you learn.** If you hit an issue not documented here, add it. If something here is wrong or outdated, fix it.
- **Context matters.** The staging Odoo database is periodically synced from production, so the state drifts. Conditions described here may not be permanent.

---

## Odoo Source & Package

| Component | Path / Location |
|-----------|----------------|
| Super repo | `~/Sites/odoo-development` (builds container image) |
| Custom addons (submodule) | `~/Sites/odoo-development/addons/custom` |
| Container image | `ghcr.io/hayden-agencies/odoo` — tag: `18.0.YYYYMMDD.HHMM-<super-repo-short-sha>` |

```bash
# Recent custom addon commits (what changed)
cd ~/Sites/odoo-development/addons/custom && git log --oneline -10

# Super repo commits (which builds include what — references submodule SHA ranges)
cd ~/Sites/odoo-development && git log --oneline -10

# Map image tag to submodule commits
cd ~/Sites/odoo-development && git log --oneline -1 <short-sha-from-tag>

# Published images
gh api orgs/hayden-agencies/packages/container/odoo/versions \
  -q '.[0:5] | .[] | "\(.metadata.container.tags // ["untagged"] | join(",")) \(.updated_at)"'

# Check which image a staging pod is running
kubectl get pods -n business-system-staging -l app.kubernetes.io/name=odoo-staging \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

---

## Environment Overview

### Odoo Staging

| Property | Value |
|----------|-------|
| Namespace | `business-system-staging` |
| Pod label | `odoo-staging` |
| Ports | 8072 (gevent/HTTP), 8071 (xmlrpc), 8069 (configured but not listening) |
| Database host | `odoo-pg-staging-rw.business-system-staging.svc.cluster.local` |
| Database name | `prod` (synced from production — not named "odoo") |
| Database user/pass | `odoo` / sourced from env var `POSTGRES_PASSWORD` |
| XMLRPC endpoint | `http://localhost:8072/xmlrpc/2/common` (from within the pod) |
| Config file | `/etc/odoo/odoo.conf` |
| `list_db` | `False` (DB listing disabled — you must know the DB name) |

### Magento Staging

| Property | Value |
|----------|-------|
| URL | `https://staging.haydenagencies.com.au` |
| Admin URL | `https://staging.haydenagencies.com.au/haydenadmin` |
| Auth | Bearer token (single access token, not OAuth1 4-key) |
| Behind Cloudflare | Yes — requests with bare `Python-urllib` user-agent get 403/1010 |

### Integration Module (Ventor)

| Property | Value |
|----------|-------|
| Integration table | `sale_integration` (id=1 is Hayden-Magento2) |
| API credentials table | `sale_integration_api_field` (keyed by `sia_id`) |
| Key fields | `url` (Shop URL), `admin_url`, `key` (Access Token) |
| Payment methods | `integration_sale_order_payment_method_external` |
| Order input files | `sale.integration.input.file` |
| Queue jobs | `queue.job` (OCA queue_job module) |

---

## Accessing Odoo Staging

### XMLRPC Access

The admin user in the staging database is **not** `admin` — it is whatever was synced from production (e.g. `integration@haydenagencies.com.au`, user id=2). The `ODOO_MASTER_PASSWORD` env var is the Odoo master password, **not** the database user password.

To get XMLRPC access, you may need to set a temporary password via direct DB:

```python
# From within the pod
import psycopg2
from passlib.context import CryptContext

conn = psycopg2.connect(host='...rw...', port=5432, user='odoo', password='<POSTGRES_PASSWORD>', dbname='prod')
cur = conn.cursor()
ctx = CryptContext(schemes=['pbkdf2_sha512'])
cur.execute("UPDATE res_users SET password = %s WHERE id = 2 RETURNING login", (ctx.hash('temp-pass'),))
conn.commit()
```

Then authenticate via XMLRPC:

```python
import xmlrpc.client
url = 'http://localhost:8072'
common = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/common')
uid = common.authenticate('prod', 'integration@haydenagencies.com.au', 'temp-pass', {})
models = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/object')
```

### Direct Database Access

From within the pod, psycopg2 is available and often more reliable than XMLRPC (which has serialization issues with certain return types):

```python
import psycopg2
conn = psycopg2.connect(
    host='odoo-pg-staging-rw.business-system-staging.svc.cluster.local',
    port=5432, user='odoo', password='<from env>', dbname='prod')
```

---

## Testing the Integration End-to-End

### 1. Verify Credentials Are Correct

```python
# From within the pod — check current API field values
cur.execute("SELECT name, value FROM sale_integration_api_field WHERE sia_id = 1 AND name IN ('url', 'admin_url', 'key')")
```

The `key` field is the Magento **Access Token** used as a bearer token. The integration does **not** use OAuth1 (consumer key/secret/access token secret are not stored).

### 2. Test Magento Connectivity

```python
# Must set User-Agent to avoid Cloudflare 1010 block
req = urllib.request.Request('https://staging.haydenagencies.com.au/rest/V1/store/storeConfigs')
req.add_header('Authorization', 'Bearer <access_token>')
req.add_header('User-Agent', 'Odoo/18.0')
resp = urllib.request.urlopen(req, timeout=15)
```

You can also use the ORM method:
```python
models.execute_kw(db, uid, password, 'sale.integration', 'action_check_connection', [[1]])
# Returns: {'type': 'ir.actions.client', 'tag': 'display_notification', 'params': {'message': 'Connection test successful!', ...}}
```

### 3. Activate the Integration

```python
models.execute_kw(db, uid, password, 'sale.integration', 'action_active', [[1]])
```

This will throw an XMLRPC serialization error (the return value is an action dict that can't be marshalled), but the state change **does commit**. Verify with:

```python
models.execute_kw(db, uid, password, 'sale.integration', 'read', [[1]], {'fields': ['state']})
# Should return: [{'id': 1, 'state': 'active'}]
```

To deactivate: `action_draft` method.

### 4. Create a Test Order on Magento Staging

Key requirements for a valid test order:

- **Payment method must be mapped** in Odoo. Check existing methods:
  ```sql
  SELECT code FROM integration_sale_order_payment_method_external WHERE integration_id = 1;
  ```
  Use one of the mapped codes (e.g. `ewayrapid`, `stripe_payments`). **Do not use `checkmo`** — it is not mapped and will fail.

- **Shipping totals must be populated.** The Ventor parser accesses `shipping_assignments[0].shipping.total.shipping_amount`. Orders created via the Magento REST API without explicit shipping totals will fail with `TypeError: list indices must be integers or slices, not str`.

- **Company field is required** on addresses (Magento staging has this validation enabled).

Minimal working order:

```python
addr = {
    'firstname': 'Test', 'lastname': 'Order', 'company': 'Test Co',
    'street': ['123 Test St'], 'city': 'Melbourne',
    'region_code': 'VIC', 'region': 'Victoria', 'region_id': 570,
    'country_id': 'AU', 'postcode': '3000', 'telephone': '0400000000',
    'email': 'test@example.com'
}

order_data = {
    'entity': {
        'customer_email': 'test@example.com',
        'customer_firstname': 'Test', 'customer_lastname': 'Order',
        'customer_is_guest': 1, 'store_id': 1,
        'base_currency_code': 'AUD', 'order_currency_code': 'AUD',
        'items': [{
            'sku': '796733000225',  # Ultra Hi Float (710ml) — known to exist
            'name': 'Ultra Hi Float (710ml)',
            'qty_ordered': 1, 'price': 18.40,
            'row_total': 18.40, 'base_row_total': 18.40,
            'product_type': 'simple'
        }],
        'billing_address': addr,
        'payment': {'method': 'ewayrapid'},
        'status': 'processing', 'state': 'processing',
        'subtotal': 18.40, 'base_subtotal': 18.40,
        'shipping_amount': 10.00, 'base_shipping_amount': 10.00,
        'shipping_incl_tax': 11.00, 'base_shipping_incl_tax': 11.00,
        'shipping_tax_amount': 1.00,
        'tax_amount': 2.84, 'base_tax_amount': 2.84,
        'grand_total': 31.24, 'base_grand_total': 31.24,
        'total_qty_ordered': 1,
        'shipping_description': 'Flat Rate - Fixed',
        'extension_attributes': {
            'shipping_assignments': [{
                'shipping': {
                    'address': addr,
                    'method': 'flatrate_flatrate',
                    'total': {
                        'shipping_amount': 10.00,
                        'base_shipping_amount': 10.00,
                        'shipping_incl_tax': 11.00,
                        'base_shipping_incl_tax': 11.00,
                        'shipping_tax_amount': 1.00
                    }
                },
                'items': [{
                    'sku': '796733000225',
                    'name': 'Ultra Hi Float (710ml)',
                    'qty_ordered': 1, 'price': 18.40,
                    'product_type': 'simple'
                }]
            }]
        }
    }
}

# POST to /rest/V1/orders with Bearer token and User-Agent header
```

### 5. Trigger the Order Import

```python
models.execute_kw(db, uid, password, 'sale.integration', 'integrationApiReceiveOrders', [[1]])
```

Same XMLRPC serialization caveat — will error but does execute. The method fetches all orders in `processing` (and other configured statuses) from Magento and creates `sale.integration.input.file` records, then queues jobs.

### 6. Monitor the Queue

```python
models.execute_kw(db, uid, password, 'queue.job', 'search_read',
    [[['date_created', '>=', '2026-02-12 00:00:00']]],
    {'fields': ['state', 'func_string', 'exc_name', 'date_created'], 'order': 'date_created desc'})
```

The import is a two-phase pipeline:
1. **`run_current_pipeline()`** — parses the Magento order JSON
2. **`create_order_from_input()`** — creates/updates the Odoo sale order

### 7. Verify the Import

```python
# Check the sale order was created/updated
models.execute_kw(db, uid, password, 'sale.order', 'read', [[<order_id>]],
    {'fields': ['name', 'state', 'amount_total', 'integration_id']})
```

---

## Calling Private ORM Methods (odoo shell)

XMLRPC cannot call `_private` methods. Use `odoo shell` inside the pod instead:

```bash
POD=$(kubectl get pods -n business-system-staging -l app.kubernetes.io/name=odoo-staging -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n business-system-staging $POD -- bash -c '
odoo shell -d prod --no-http --stop-after-init --db_user=$POSTGRES_USER --db_password=$POSTGRES_PASSWORD <<SHELLEOF
order = env["sale.order"].browse(ORDER_ID)
result = order._integration_validate_picking()
print(result)
env.cr.commit()
SHELLEOF
'
```

**Critical**: you must pass `--db_user=$POSTGRES_USER --db_password=$POSTGRES_PASSWORD` — `odoo.conf` does not contain the DB password (it comes from env vars at runtime). Without these flags odoo shell fails with `fe_sendauth: no password supplied`.

---

## Custom Addons Path

Addons are at `/mnt/extra-addons/custom/`, `/mnt/extra-addons/vendor-oca/`, `/mnt/extra-addons/vendor-ventor/`, `/mnt/enterprise-addons` (per `addons_path` in `/etc/odoo/odoo.conf`). **Not** `/opt/odoo/`.

Verify deployed code:
```bash
kubectl exec -n business-system-staging $POD -- grep -c "some_function" /mnt/extra-addons/custom/module_name/models/file.py
```

---

## Simulating Queue Job State for Guard Testing

Queue jobs complete too fast for XMLRPC round-trips to catch them in `started` state. To test guards that check for active jobs, use direct SQL to temporarily set a done job to `started`, call the method, then verify and restore:

```python
cur.execute("UPDATE queue_job SET state = 'started' WHERE id = %s", (job_id,))
# ... call method via XMLRPC or odoo shell ...
cur.execute("UPDATE queue_job SET state = 'done' WHERE id = %s", (job_id,))
```

---

## Creating Sale Orders Directly in Odoo (Bypassing Magento)

When Magento staging increment IDs collide with production orders in the synced DB, create orders directly via XMLRPC to get a clean test:

```python
order_id = models.execute_kw(db, uid, pw, 'sale.order', 'create', [{
    'partner_id': partner_id,
    'integration_id': 1,
    'order_line': [(0, 0, {'product_id': product_id, 'product_uom_qty': 2, 'price_unit': 10.00})]
}])
models.execute_kw(db, uid, pw, 'sale.order', 'action_confirm', [[order_id]])
```

Create fulfillment records via SQL (ORM model: `external.order.fulfillment`, table: `external_order_fulfillment`):

```sql
INSERT INTO external_order_fulfillment
    (erp_order_id, name, internal_status, external_str_id, external_order_str_id, create_uid, write_uid, create_date, write_date)
VALUES (ORDER_ID, 'TEST', 'draft', 'TEST-1', 'TEST-1', 2, 2, now(), now())
RETURNING id;

INSERT INTO external_order_fulfillment_line
    (fulfillment_id, quantity, fulfillable_quantity, external_str_id, code, external_reference, create_uid, write_uid, create_date, write_date)
VALUES (FULFILLMENT_ID, 2, 0, 'LINE-1', 'SKU', 'REF-1', 2, 2, now(), now());
```

`internal_status = 'draft'` → `is_ecommerce_ok=True, is_done=False` (eligible for validation).

---

## Odoo 18 Product Types

All products are `consu` — Odoo 18 unified `product` and `consu` types. There is no `type = 'product'`. `qty_available` is a computed non-stored field — **cannot use it in `search_read` domain or order**. Use `stock_quant` table via SQL instead.

---

## Known Gotchas

### XMLRPC Serialization Errors

Many Ventor integration methods return Odoo recordsets or action dicts that can't be serialized over XMLRPC. The pattern is:
- Method executes successfully and commits
- XMLRPC throws a `Fault` with `KeyError: <class 'odoo.api...'>` or similar
- **This is not a real error.** Verify the result by reading the state afterwards.

### Staging DB Has Production Order Numbers

The staging Odoo DB is synced from production. Magento staging increment IDs collide with existing production orders in Odoo — the integration **matches and updates** the existing order rather than creating a new one. To test with a clean order, create directly in Odoo (see above).

### Cloudflare Blocks Python User-Agent

Any HTTP request from the pod to `staging.haydenagencies.com.au` without a browser-like `User-Agent` header will get a `403` with Cloudflare error code `1010`. Always set:
```python
req.add_header('User-Agent', 'Odoo/18.0')
```

The Odoo integration module's own HTTP client handles this, so it only affects manual testing.

### `receive_order_statuses` Includes `canceled`

The integration fetches orders in **all configured statuses**, including `canceled`. If there are canceled test orders on Magento staging, they will be fetched and Odoo will attempt to cancel the corresponding local orders. Locked orders will fail with `UserError: You cannot cancel a locked order`.

To avoid this, either:
- Only create test orders with `processing` status and clean them up after
- Or remove `canceled` from `receive_order_statuses` in staging

### Payment Method Must Be Pre-Mapped

The Ventor module requires payment methods to exist in `integration_sale_order_payment_method_external`. If the Magento order uses a method not in this table, the import fails with `ApiImportError: External payment method with the code "..." not found`.

Currently mapped methods (integration_id=1):
`ewayrapid`, `paypal_express`, `partial_invoice`, `stripe_payments`, `free`, `stripe_payments_invoice`, `cashondelivery`, `banktransfer`, `purchaseorder`, `payonpickup`, `customercredit`

### Port 8069 Is Not Listening

Despite being configured in `odoo.conf` as `http_port = 8069`, the actual HTTP/XMLRPC traffic goes through **port 8072** (gevent). Always use 8072 for XMLRPC calls from within the pod.

### queue.job Date Field

The `queue.job` model uses `date_created` (not `create_date`) for filtering. Using `create_date` will raise `ValueError: Invalid field queue.job.create_date`.

---

## Updating Integration Credentials

When the staging Magento integration token changes (e.g. after a database sync overwrites settings):

```sql
-- Update via direct SQL (fastest)
UPDATE sale_integration_api_field SET value = 'https://staging.haydenagencies.com.au'
  WHERE sia_id = 1 AND name = 'url';
UPDATE sale_integration_api_field SET value = 'https://staging.haydenagencies.com.au/haydenadmin'
  WHERE sia_id = 1 AND name = 'admin_url';
UPDATE sale_integration_api_field SET value = '<new_access_token>'
  WHERE sia_id = 1 AND name = 'key';
UPDATE sale_integration SET payload_url = 'https://odoo-staging-webhook.haydenagencies.com.au/prod/integration/magento2/1/<type>'
  WHERE id = 1;
```

The `key` field is the **Magento Integration Access Token** (used as a Bearer token). The consumer key/secret and access token secret from Magento's integration page are **not used** by this module.

---

## Cleaning Up After Tests

```python
# Delete input files
models.execute_kw(db, uid, password, 'sale.integration.input.file', 'unlink', [[file_ids]])

# Delete queue jobs
models.execute_kw(db, uid, password, 'queue.job', 'unlink', [[job_ids]])

# Cancel test orders on Magento (POST with entity_id and status=canceled)
# Or update status via API: POST /rest/V1/orders with entity.entity_id and entity.status='canceled'
```

---

## Changelog

| Date | What Changed |
|------|-------------|
| 2026-02-12 | Initial version. Documented environment, e2e test flow, shipping/payment/Cloudflare gotchas. |
| 2026-02-12 | Added: odoo shell with DB creds, custom addons path, queue job state simulation, direct order creation bypassing Magento, fulfillment SQL, Odoo 18 product type note. |
