-- Reusable view for further analysis, as a baseline
-- Replaces it too in case it's already made
CREATE OR REPLACE VIEW retail_sales AS
SELECT
    *,
    quantity * unit_price AS line_revenue,
    DATE_TRUNC('month', invoice_date)::date AS invoice_month
FROM retail_transactions
WHERE quantity > 0
  AND unit_price > 0
  AND LEFT(UPPER(TRIM(invoice_no)), 1) <> 'C';

SELECT *
FROM retail_sales rs
LIMIT 10;

-- Monthly Sales View

CREATE OR REPLACE VIEW monthly_sales AS
WITH order_totals AS (
    SELECT
        invoice_month,
        invoice_no,
        SUM(line_revenue) AS order_value,
        SUM(quantity) AS order_units
    FROM retail_sales
    GROUP BY invoice_month, invoice_no
)
SELECT
    invoice_month,
    SUM(order_value) AS sales_value,
    SUM(order_units) AS units_sold,
    COUNT(*) AS sales_invoices,
    ROUND(AVG(order_value), 2) AS average_order_value,
    ROUND(AVG(order_units::numeric), 2) AS average_units_per_order
FROM order_totals
GROUP BY invoice_month;

-- Product Performance

CREATE OR REPLACE VIEW product_sales AS
SELECT
    stock_code,
    MAX(description) AS description,
    SUM(quantity) AS units_sold,
    SUM(line_revenue) AS sales_value,
    COUNT(DISTINCT invoice_no) AS sales_invoices
FROM retail_sales
GROUP BY stock_code;

-- Country Performance

CREATE OR REPLACE VIEW country_sales AS
SELECT
    country,
    SUM(line_revenue) AS sales_value,
    SUM(quantity) AS units_sold,
    COUNT(DISTINCT invoice_no) AS sales_invoices,
    COUNT(DISTINCT customer_id) AS identifiable_customers
FROM retail_sales
GROUP BY country;

-- Customer Metrics

CREATE OR REPLACE VIEW customer_metrics AS
SELECT
    customer_id,
    COUNT(DISTINCT invoice_no) AS invoice_count,
    SUM(line_revenue) AS sales_value,
    MIN(invoice_date) AS first_purchase,
    MAX(invoice_date) AS last_purchase,
    (
        (SELECT MAX(invoice_date)::date FROM retail_sales) + 1
        - MAX(invoice_date)::date
    ) AS recency_days
FROM retail_sales
WHERE customer_id IS NOT NULL
GROUP BY customer_id;

-- Cancellation Activity by Month

CREATE OR REPLACE VIEW monthly_cancellations AS
SELECT
    DATE_TRUNC('month', invoice_date)::date AS invoice_month,
    COUNT(DISTINCT invoice_no) AS cancellation_invoices,
    COUNT(*) AS cancellation_lines,
    SUM(ABS(quantity * unit_price)) AS absolute_line_value
FROM retail_transactions
WHERE LEFT(UPPER(TRIM(invoice_no)), 1) = 'C'
GROUP BY DATE_TRUNC('month', invoice_date)::date;

-- Customer Cohort Retention

CREATE OR REPLACE VIEW cohort_retention AS
WITH customer_months AS (
    SELECT DISTINCT
        customer_id,
        DATE_TRUNC('month', invoice_date)::date AS activity_month
    FROM retail_sales
    WHERE customer_id IS NOT NULL
),
cohorts AS (
    SELECT
        customer_id,
        MIN(activity_month) AS cohort_month
    FROM customer_months
    GROUP BY customer_id
),
activity AS (
    SELECT
        c.cohort_month,
        m.activity_month,
        (
            (EXTRACT(YEAR FROM m.activity_month)
             - EXTRACT(YEAR FROM c.cohort_month)) * 12
            + EXTRACT(MONTH FROM m.activity_month)
            - EXTRACT(MONTH FROM c.cohort_month)
        )::integer AS month_number,
        m.customer_id
    FROM customer_months m
    JOIN cohorts c USING (customer_id)
),
retention AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT customer_id) AS active_customers
    FROM activity
    GROUP BY cohort_month, month_number
)
SELECT
    cohort_month,
    month_number,
    active_customers,
    ROUND(
        100.0 * active_customers
        / NULLIF(
            MAX(active_customers) FILTER (WHERE month_number = 0)
                OVER (PARTITION BY cohort_month),
            0
        ),
        2
    ) AS retention_pct
FROM retention;

-- RFM customer segmentation (Recency, Frequency, and Monetary)
CREATE OR REPLACE VIEW customer_rfm AS
WITH latest_date AS (
    SELECT MAX(invoice_date)::date AS max_date
    FROM retail_transactions
),
customer_rfm AS (
    SELECT
        t.customer_id,
        (d.max_date + 1 - MAX(t.invoice_date)::date) AS recency_days,
        COUNT(DISTINCT t.invoice_no) AS frequency,
        SUM(t.revenue) AS monetary
    FROM retail_transactions AS t
    CROSS JOIN latest_date AS d
    WHERE t.customer_id IS NOT NULL
    GROUP BY t.customer_id, d.max_date
),
scored AS (
    SELECT
        *,
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(4) OVER (ORDER BY frequency ASC) AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC) AS m_score
    FROM customer_rfm
)
SELECT
    customer_id,
    recency_days,
    frequency,
    ROUND(monetary, 2) AS monetary,
    r_score,
    f_score,
    m_score,
    CASE
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3
            THEN 'High Value Active'
        WHEN r_score >= 3 AND f_score >= 3
            THEN 'Low Value Active'
        WHEN r_score = 1 AND f_score >= 3
            THEN 'Previously Frequent, Inactive'
        WHEN r_score >= 3 AND f_score <= 2
            THEN 'Recent, Low Frequency'
        ELSE 'Other'
    END AS customer_segment
FROM scored
ORDER BY monetary DESC;

-- Tests views to see if errors show up

SELECT * 
FROM retail_sales 
LIMIT 10;

SELECT * 
FROM monthly_sales 
ORDER BY invoice_month
LIMIT 10;

SELECT * 
FROM product_sales
ORDER BY sales_value DESC
LIMIT 10;

SELECT * 
FROM country_sales
ORDER BY sales_value DESC
LIMIT 10;

SELECT * 
FROM customer_metrics
LIMIT 10;

SELECT * 
FROM monthly_cancellations
ORDER BY invoice_month
LIMIT 10;

SELECT * 
FROM cohort_retention
ORDER BY cohort_month, month_number
LIMIT 10;

SELECT *
FROM customer_rfm
LIMIT 10;