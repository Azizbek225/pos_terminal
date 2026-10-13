-- Hisobotlar uchun qulay VIEW lar (PostgreSQL).
-- Server yozuvlarni `sync_records` jadvalida JSONB ko'rinishida saqlaydi;
-- bu VIEW lar ularni oddiy jadval kabi o'qish imkonini beradi (Excel, Metabase, Power BI ...).
--
-- O'rnatish (server bir marta ishga tushib, jadvallar yaratilgandan keyin):
--   docker compose exec -T db psql -U pos -d pos < sql/views.sql

CREATE OR REPLACE VIEW v_sales AS
SELECT
  id,
  data->>'receipt_no'                                   AS receipt_no,
  to_timestamp((data->>'created_at')::bigint / 1000.0)  AS created_at,
  data->>'cashier_name'                                 AS cashier_name,
  data->>'payment_type'                                 AS payment_type,
  data->>'status'                                       AS status,
  (data->>'subtotal')::bigint                           AS subtotal,
  (data->>'discount_amount')::bigint                    AS discount_amount,
  (data->>'total')::bigint                              AS total,
  device_id
FROM sync_records
WHERE entity = 'sales' AND NOT deleted;

CREATE OR REPLACE VIEW v_sale_items AS
SELECT
  id,
  data->>'sale_id'                  AS sale_id,
  data->>'product_id'               AS product_id,
  data->>'product_name'             AS product_name,
  (data->>'qty')::numeric           AS qty,
  (data->>'price')::bigint          AS price,
  (data->>'line_total')::bigint     AS line_total
FROM sync_records
WHERE entity = 'sale_items' AND NOT deleted;

CREATE OR REPLACE VIEW v_products AS
SELECT
  id,
  data->>'name'                     AS name,
  data->>'barcode'                  AS barcode,
  data->>'sku'                      AS sku,
  data->>'unit'                     AS unit,
  (data->>'purchase_price')::bigint AS purchase_price,
  (data->>'sale_price')::bigint     AS sale_price,
  (data->>'min_stock')::numeric     AS min_stock
FROM sync_records
WHERE entity = 'products' AND NOT deleted;

-- Qoldiq = barcha ombor harakatlari yig'indisi (qurilmalar bo'yicha birlashtirilgan).
CREATE OR REPLACE VIEW v_stock AS
SELECT
  p.id,
  p.name,
  COALESCE(SUM((m.data->>'qty')::numeric), 0) AS stock_qty
FROM v_products p
LEFT JOIN sync_records m
  ON m.entity = 'stock_movements' AND m.data->>'product_id' = p.id
GROUP BY p.id, p.name;

CREATE OR REPLACE VIEW v_daily_sales AS
SELECT
  date_trunc('day', created_at)::date AS day,
  count(*)                            AS receipts,
  sum(total)                          AS total,
  round(avg(total))                   AS average
FROM v_sales
WHERE status = 'completed'
GROUP BY 1
ORDER BY 1;

-- Firmalar oldidagi qarz: kirimlar yig'indisi - to'lovlar yig'indisi.
CREATE OR REPLACE VIEW v_supplier_debts AS
SELECT
  s.id,
  s.data->>'name' AS name,
  COALESCE((SELECT SUM((p.data->>'total')::bigint) FROM sync_records p
            WHERE p.entity = 'supplier_purchases' AND NOT p.deleted AND p.data->>'supplier_id' = s.id), 0) AS purchased,
  COALESCE((SELECT SUM((m.data->>'amount')::bigint) FROM sync_records m
            WHERE m.entity = 'supplier_payments' AND NOT m.deleted AND m.data->>'supplier_id' = s.id), 0) AS paid
FROM sync_records s
WHERE s.entity = 'suppliers' AND NOT s.deleted;
