-- Verifies you're in the right area

SELECT
    current_database() AS database_name,
    current_user AS username,
    inet_server_addr() AS server_address,
    inet_server_port() AS server_port;

-- Check if table was created from import

SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_name = 'retail_transactions';

-- Check if total rows matches import from Python scripts

SELECT COUNT(*) AS total_rows
FROM retail_transactions;

-- Check if information shows up as expected from cleaned data

SELECT *
FROM retail_transactions
LIMIT 20;

-- Checks if derived column (e.g. revenue) is working as intended

SELECT
    COUNT(*) AS total_rows,
    COUNT(revenue) AS rows_with_revenue,
    SUM(revenue) AS net_revenue,
    MIN(invoice_date) AS first_transaction,
    MAX(invoice_date) AS last_transaction
FROM retail_transactions;

-- Checks for quality issues (missing IDs, negative rows, cancellations, other issues, etc.)

SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (
        WHERE customer_id IS NULL
    ) AS missing_customer_ids,
    COUNT(*) FILTER (
        WHERE quantity < 0
    ) AS negative_quantity_rows,
    COUNT(*) FILTER (
        WHERE unit_price < 0
    ) AS negative_price_rows,
    COUNT(*) FILTER (
        WHERE invoice_no LIKE 'C%'
    ) AS cancellation_invoice_rows
FROM public.retail_transactions;