# Odoo Duplicate SKU Remediation Tasks

**Created:** 2026-02-05
**Issue:** Duplicate products with same SKU causing stock mismatches and failed "Validate Picking" jobs

## Problem Summary

The Magento-Odoo integration created duplicate products with identical SKUs. Stock exists on the INACTIVE duplicates while orders reference the ACTIVE products (which have zero stock). This causes "Validate Picking" jobs to fail because Odoo cannot reserve/pick items that have no stock on the active product.

**Root Cause (IDENTIFIED):**
1. **Oct 14, 2025**: ~18,000 products were bulk imported OUTSIDE the Magento integration (no mappings created)
2. **Oct 30 - Nov 14, 2025**: Orders arrived from Magento for unmapped products
3. **Integration behavior**: Matches by Magento product ID, not SKU. With `auto_create_products_on_so=true`, it created NEW products with proper mappings instead of finding existing ones
4. **Result**: 18 products exist as duplicates - originals have stock but no mapping, duplicates have mapping but no stock
5. **Consequence**: Original products deactivated, stock trapped, orders fail

---

## PART 1: Immediate Order Resolution

### Task 1.1: Mark Failed Queue Jobs as Done

**Location:** Odoo > Queue > Jobs (filter by State = Failed)

**Steps:**
1. Navigate to Queue > Jobs in Odoo
2. Filter: `State = Failed` AND `Name contains "Validate Picking"`
3. Select all 4 failed jobs (including order 100290210)
4. Click Action > "Set to Done"

**Why:** These are informational jobs that alert users to stock issues. They don't need to be requeued - they just need acknowledgment.

**Affected Jobs:**
- Job ID 1545341: Order 100290210 - "No Magento shipments to apply"
- Job ID 1545318: Order 100290210 - "remaining pickings are waiting for stock"
- (2 other similar jobs)

---

### Task 1.2: Resolve Order 100290210 Picking

**Order Details:**
- Order: 100290210 (Odoo sale.order ID: 314341)
- Pending Picking: TECH/OUT/285655 (state: confirmed)
- Missing Item: "Lagenda Mini Helium Digital Sizer Inflator" (SKU: MG-09191, product_id: 20532)
- Quantity Needed: 1 unit

**Option A - Transfer Stock (Recommended):**
1. Go to Inventory > Operations > Inventory Adjustments
2. Create new adjustment for product 20532 (active MG-09191)
3. Add 1 unit to Stock location
4. Validate the adjustment
5. Go to picking TECH/OUT/285655 and click "Check Availability"
6. Process the picking

**Option B - Cancel Backorder:**
1. If item won't be shipped, go to picking TECH/OUT/285655
2. Cancel the picking
3. Update the sale order accordingly
4. Communicate with customer about partial fulfillment

---

## PART 2: Inventory Stock Transfer

### ALTERNATIVE: Fix Mappings Instead of Transferring Stock

Instead of transferring stock to duplicate products, you could redirect Magento mappings to the ORIGINAL products (which have stock). This is cleaner if originals have order history.

**Steps:**
1. Delete the duplicate products (20532, 20557, 20563, 20569, 20591, 20626, 20558)
2. Update mappings to point to original products
3. Reactivate original products

**SQL to redirect mappings (BACKUP FIRST):**
```sql
-- Example: Point MG-09191 mapping to original product 9218 instead of duplicate 20532
UPDATE integration_product_product_mapping
SET product_id = 9218, write_date = NOW()
WHERE product_id = 20532 AND integration_id = 1;

-- Reactivate original product
UPDATE product_product SET active = true, write_date = NOW() WHERE id = 9218;

-- Archive duplicate (don't delete - keep for audit)
UPDATE product_product SET active = false, default_code = 'MG-09191-DUP-ARCHIVED', write_date = NOW() WHERE id = 20532;
```

**WARNING:** Only do this if duplicate products have NO order history. Check first:
```sql
SELECT COUNT(*) FROM sale_order_line WHERE product_id IN (20532, 20557, 20563, 20569, 20591, 20626, 20558);
```

---

### Task 2.1: Transfer Trapped Stock from Inactive Products

**Products requiring stock transfer:**

| SKU | FROM (Inactive) | TO (Active) | Qty to Transfer |
|-----|-----------------|-------------|-----------------|
| MG-09191 | product_id: 9218 | product_id: 20532 | 6 units |
| MG-15781 | product_id: 20569 | Find active duplicate | 6 units |
| MG-15782 | product_id: 20591 | Find active duplicate | 6 units |
| MG-15784 | product_id: 20626 | Find active duplicate | 8 units |
| MG-18703 | product_id: 20558 | Find active duplicate | 4 units |

**Steps for each SKU:**
1. Go to Inventory > Products, search by SKU
2. Identify the ACTIVE product variant
3. Go to Inventory > Operations > Inventory Adjustments
4. Create adjustment to ADD stock to the active product
5. Validate
6. Optionally: Create adjustment to REMOVE stock from inactive product (cleanup)

**SQL to find active product IDs for each SKU:**
```sql
SELECT pp.id, pp.default_code, pp.active
FROM product_product pp
WHERE pp.default_code IN ('MG-15781', 'MG-15782', 'MG-15784', 'MG-18703')
ORDER BY pp.default_code, pp.active DESC;
```

---

### Task 2.2: Verify Stock After Transfer

**Verification Query (run in PostgreSQL):**
```sql
SELECT pp.default_code as sku, pp.id, pp.active,
       COALESCE(SUM(sq.quantity) FILTER (WHERE sl.usage = 'internal'), 0) as stock
FROM product_product pp
LEFT JOIN stock_quant sq ON sq.product_id = pp.id
LEFT JOIN stock_location sl ON sq.location_id = sl.id
WHERE pp.default_code IN ('MG-09191', 'MG-15781', 'MG-15782', 'MG-15784', 'MG-18703')
GROUP BY pp.id, pp.default_code, pp.active
ORDER BY pp.default_code, pp.active DESC;
```

**Expected Result:** Active products should have stock, inactive should have 0.

---

## PART 3: Duplicate Product Cleanup

### Task 3.1: Merge or Archive Duplicate Products

**For each duplicate SKU pair, decide:**

**Option A - Merge Products (if both have history):**
1. Export all sale order lines, purchase order lines, stock moves referencing the inactive product
2. Update references to point to active product
3. Archive (don't delete) the inactive product

**Option B - Keep Separate (if needed for historical records):**
1. Rename inactive product SKU to add suffix (e.g., MG-09191-OLD)
2. This prevents future mapping conflicts

**List of all duplicates to review:**
```
MG-09191, MG-11788, MG-12046, MG-15781, MG-15782, MG-15784,
MG-18703, MG-20344, MG-20476, MG-20483, MG-20489, MG-20490,
customshippingrate_standard
```

---

### Task 3.2: Update Magento Product Mappings

**Location:** Odoo > Sales > Integrations > Hayden-Magento2 > Product Mappings

**Steps:**
1. Search for each affected SKU in the integration mappings
2. Verify the external Magento product ID maps to the ACTIVE Odoo product
3. If mapped to inactive product, update the mapping to active product
4. Test by triggering a product sync from Magento

---

## PART 4: Root Cause Prevention

### Task 4.1: ROOT CAUSE IDENTIFIED ✓

**Timeline of Events:**
1. **Oct 12, 2025**: Hayden-Magento2 integration was configured
2. **Oct 14, 2025**: ~18,000 products bulk imported into Odoo (by thomas@haydenagencies.com.au)
   - Import was done OUTSIDE the integration (likely via Odoo's standard import or migration script)
   - Products were created with SKUs but **NO Magento mappings** were created
3. **Oct 30, 2025**: First Magento product mappings created (integration starts syncing)
4. **Nov 3-14, 2025**: Orders arrive from Magento for products without mappings
   - Integration looks for products by Magento product ID (not SKU)
   - Cannot find mappings for 18 specific products
   - `auto_create_products_on_so = true` setting causes creation of duplicate products WITH mappings
5. **Later**: Original products deactivated (seen as duplicates), but stock remained on them

**Root Cause:** The Oct 14 bulk import bypassed the Magento integration, creating products in Odoo without the corresponding `integration_product_product_mapping` records. The integration matches by Magento product ID (`integration_product_product_external.code`), NOT by SKU.

**18 Products Affected (No Magento Mapping):**
```sql
-- Products created Oct 14 without mappings (includes our problem SKUs)
SELECT pp.id, pp.default_code, pp.active
FROM product_product pp
LEFT JOIN integration_product_product_mapping ppm ON ppm.product_id = pp.id
WHERE pp.create_date::date = '2025-10-14' AND ppm.id IS NULL;
```
Result: MG-09191, MG-11617, MG-11618, MG-11710, MG-11711, MG-11712, MG-11788, MG-12046, MG-15781, MG-15782, MG-15784, MG-15833, MG-15836, MG-15837, MG-18703, MG-19901, and 2 blank SKUs.

---

### Task 4.2: Add SKU Uniqueness Constraint (Optional)

**Warning:** Only do this after cleaning up duplicates!

**In Odoo:**
1. Go to Settings > Technical > Database Structure > Models
2. Find product.product model
3. Consider adding SQL constraint for unique active SKUs

**Or via SQL:**
```sql
-- First verify no active duplicates exist
SELECT default_code, COUNT(*)
FROM product_product
WHERE active = true AND default_code IS NOT NULL
GROUP BY default_code
HAVING COUNT(*) > 1;

-- If clean, add partial unique index
CREATE UNIQUE INDEX idx_product_sku_unique_active
ON product_product (default_code)
WHERE active = true AND default_code IS NOT NULL AND default_code != '';
```

---

### Task 4.3: Configure Integration to Prevent Future Duplicates

**Current Configuration (Hayden-Magento2):**
```
auto_create_products_on_so = TRUE  <-- This caused duplicates
product_reference_id = 21
template_reference_id = 15
```

**Option A - Disable Auto-Create (Recommended for stable catalogs):**
```
Location: Odoo > Sales > Integrations > Hayden-Magento2 > Settings
Set "Auto Create Products on Sales Order" = False
```
This prevents automatic product creation when orders contain unknown products. Orders will fail instead of creating duplicates.

**Option B - Keep Auto-Create but Add SKU Fallback Matching:**
The integration matches by Magento product ID, not SKU. If products are imported outside the integration:
1. ALWAYS use the integration's product import feature
2. OR manually create mappings after external imports

**For Future Imports - CRITICAL:**
Never bulk import products outside the Magento integration. Always use:
- Odoo > Sales > Integrations > Hayden-Magento2 > Import Products
- This creates proper mappings in `integration_product_product_mapping`

**SQL to manually create missing mapping (if needed):**
```sql
-- Example: Link existing Odoo product to Magento product
INSERT INTO integration_product_product_mapping
  (integration_id, product_id, external_product_id, create_uid, write_uid, create_date, write_date)
SELECT
  1,                    -- Hayden-Magento2 integration_id
  9218,                 -- Odoo product_product.id (original)
  ppe.id,               -- external_product_id
  1, 1, NOW(), NOW()
FROM integration_product_product_external ppe
WHERE ppe.external_reference = 'MG-09191'
  AND ppe.integration_id = 1;
```

---

## PART 5: Ongoing Monitoring

### Task 5.1: Create Scheduled Check for Duplicate SKUs

**Add to regular maintenance:** Run this query weekly to catch new duplicates:

```sql
SELECT pp.default_code as sku, COUNT(*) as duplicates
FROM product_product pp
WHERE pp.default_code IS NOT NULL
  AND pp.default_code != ''
  AND pp.active = true
GROUP BY pp.default_code
HAVING COUNT(*) > 1;
```

---

### Task 5.2: Monitor Failed Picking Jobs

**Add alert for:** Queue jobs with name containing "Validate Picking" and state = "failed"

This catches stock availability issues early before they accumulate.

---

## Quick Reference: Database Access

**Connect to Odoo PostgreSQL:**
```bash
kubectl exec -n business-system odoo-pg-1 -- psql -U postgres -d prod
```

**Key Tables:**
- `product_product` - Product variants (has SKU in default_code)
- `stock_quant` - Current stock levels by location
- `stock_move` - Stock movement history
- `sale_order` / `sale_order_line` - Sales orders
- `stock_picking` - Delivery orders/pickings
- `queue_job` - Background job queue

---

## Assignee Notes

- Priority: HIGH for Part 1 (order resolution) and Part 2 (stock transfer)
- Priority: MEDIUM for Part 3 (cleanup) and Part 4 (prevention)
- Estimated effort: 2-4 hours for immediate fixes, additional time for root cause investigation
