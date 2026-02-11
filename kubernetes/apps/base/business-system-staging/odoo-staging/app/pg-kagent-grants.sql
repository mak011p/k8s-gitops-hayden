-- Allow-list grants for kagent_readonly role
-- Run this ONCE after CNPG creates the role via managed.roles
--
-- Usage:
--   kubectl exec -it odoo-pg-staging-1 -n business-system-staging -c postgres -- \
--     psql -U postgres -d prod -f /dev/stdin < pg-kagent-grants.sql
--
-- Or inline:
--   kubectl exec -it odoo-pg-staging-1 -n business-system-staging -c postgres -- \
--     psql -U postgres -d prod -c "$(cat pg-kagent-grants.sql)"

-- Schema access
GRANT USAGE ON SCHEMA public TO kagent_readonly;

-- Sales
GRANT SELECT ON sale_order, sale_order_line TO kagent_readonly;

-- Products
GRANT SELECT ON product_product, product_template, product_category TO kagent_readonly;
GRANT SELECT ON product_pricelist, product_pricelist_item TO kagent_readonly;

-- Partners (customers/vendors)
GRANT SELECT ON res_partner, res_partner_category TO kagent_readonly;

-- Accounting
GRANT SELECT ON account_move, account_move_line TO kagent_readonly;
GRANT SELECT ON account_journal, account_account TO kagent_readonly;

-- Inventory
GRANT SELECT ON stock_picking, stock_move, stock_move_line, stock_quant TO kagent_readonly;
GRANT SELECT ON stock_warehouse, stock_location, stock_lot TO kagent_readonly;

-- Projects / tasks
GRANT SELECT ON project_project, project_task TO kagent_readonly;

-- Purchasing
GRANT SELECT ON purchase_order, purchase_order_line TO kagent_readonly;

-- Reference data
GRANT SELECT ON uom_uom, res_currency, res_currency_rate TO kagent_readonly;
GRANT SELECT ON res_company, delivery_carrier TO kagent_readonly;
GRANT SELECT ON res_country, res_country_state TO kagent_readonly;
