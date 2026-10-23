-- Import Veracity

SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE customer_id IS NULL)
        AS missing_customer_id,
    COUNT(*) FILTER (WHERE description IS NULL OR TRIM(description) = '')
        AS missing_description,
    COUNT(*) FILTER (WHERE quantity < 0)
        AS negative_quantity_rows,
    COUNT(*) FILTER (WHERE unit_price = 0)
        AS zero_price_rows,
    COUNT(*) FILTER (WHERE unit_price < 0)
        AS negative_price_rows,
    COUNT(*) FILTER (
        WHERE LEFT(UPPER(TRIM(invoice_no)), 1) = 'C'
    ) AS cancellation_marked_rows,
    COUNT(*) FILTER (
        WHERE quantity > 0 AND unit_price > 0
          AND LEFT(UPPER(TRIM(invoice_no)), 1) <> 'C'
    ) AS positive_sales_rows
FROM retail_transactions;

-- Reusable view as a base for other queries
-- Adds revenue by line & month of invoice
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

-- Monthly Sales Performance

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
GROUP BY invoice_month
ORDER BY invoice_month;

-- Verify revenue against monthly sales performance
SELECT SUM(line_revenue) AS total_sales
FROM retail_sales;

-- Top 10 Products (By Sales)

WITH product_sales AS (
    SELECT
        stock_code,
        MAX(description) AS description,
        SUM(quantity) AS units_sold,
        SUM(line_revenue) AS sales_value,
        COUNT(DISTINCT invoice_no) AS invoice_count
    FROM retail_sales
    GROUP BY stock_code
),
ranked_products AS (
	SELECT
    	*,
    	ROUND(100.0 * sales_value / NULLIF(SUM(sales_value) OVER (), 0), 2) AS pct_of_sales,
    	RANK() OVER (ORDER BY sales_value DESC) AS sales_rank
	FROM product_sales
)
SELECT *
FROM ranked_products
WHERE sales_rank <= 10
ORDER BY sales_value DESC
LIMIT 10; -- Just in case

-- Best Country
-- UK (United Kingdom) should be #1 currently, so examine #2+ further in depth
SELECT
    country,
    SUM(line_revenue) AS sales_value,
    SUM(quantity) AS units_sold,
    COUNT(DISTINCT invoice_no) AS sales_invoices,
    COUNT(DISTINCT customer_id) AS identifiable_customers
FROM retail_sales
GROUP BY country
ORDER BY sales_value DESC;

-- Repeat Customers & Sales

WITH customer_sales AS (
    SELECT
        customer_id,
        COUNT(DISTINCT invoice_no) AS invoice_count,
        SUM(line_revenue) AS sales_value,
        MIN(invoice_date) AS first_purchase,
        MAX(invoice_date) AS last_purchase
    FROM retail_sales
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
),
ranked AS (
    SELECT
        *,
        NTILE(10) OVER (ORDER BY sales_value DESC) AS revenue_decile
    FROM customer_sales -- Identifies customer SEGMENTS rather than individuals for rankings
)
SELECT
    COUNT(*) AS identifiable_customers,
    COUNT(*) FILTER (WHERE invoice_count >= 2) AS repeat_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE invoice_count >= 2)
        / NULLIF(COUNT(*), 0),
        2
    ) AS repeat_customer_pct,
    ROUND(SUM(sales_value), 2) AS identifiable_customer_sales,
    ROUND(
        100.0 * SUM(sales_value) FILTER (WHERE revenue_decile = 1)
        / NULLIF(SUM(sales_value), 0),
        2
    ) AS top_decile_revenue_pct
FROM ranked;

-- Customer Cohorts

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
            EXTRACT(YEAR FROM m.activity_month)
            - EXTRACT(YEAR FROM c.cohort_month)
        ) * 12
        + EXTRACT(MONTH FROM m.activity_month)
        - EXTRACT(MONTH FROM c.cohort_month) AS month_number,
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
        / MAX(active_customers) FILTER (WHERE month_number = 0)
          OVER (PARTITION BY cohort_month),
        2
    ) AS retention_pct
FROM retention
ORDER BY cohort_month, month_number;

-- Invoices with cancellations per month

SELECT
    DATE_TRUNC('month', invoice_date)::date AS invoice_month,
    COUNT(DISTINCT invoice_no) AS cancellation_invoices,
    COUNT(*) AS cancellation_lines,
    SUM(ABS(quantity * unit_price)) AS absolute_line_value
FROM retail_transactions
WHERE LEFT(UPPER(TRIM(invoice_no)), 1) = 'C'
GROUP BY DATE_TRUNC('month', invoice_date)::date
ORDER BY invoice_month;

-- RFM customer segmentation (Recency, Frequency, and Monetary)

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
            THEN 'High-value active'
        WHEN r_score >= 3 AND f_score >= 3
            THEN 'Loyal active'
        WHEN r_score = 1 AND f_score >= 3
            THEN 'Previously frequent, inactive'
        WHEN r_score >= 3 AND f_score <= 2
            THEN 'Recent, low frequency'
        ELSE 'Other'
    END AS customer_segment
FROM scored
ORDER BY monetary DESC;

-- Is sales value changing because of order volume, units per order, or average revenue per unit?

WITH monthly AS (
    SELECT
        invoice_month,
        SUM(line_revenue) AS sales_value,
        COUNT(DISTINCT invoice_no) AS orders,
        SUM(quantity) AS units_sold
    FROM retail_sales
    GROUP BY invoice_month
)
SELECT
    invoice_month,
    ROUND(sales_value, 2) AS sales_value,
    orders,
    units_sold,
    ROUND(sales_value / NULLIF(orders, 0), 2) AS revenue_per_order,
    ROUND(units_sold::numeric / NULLIF(orders, 0), 2)
        AS units_per_order,
    ROUND(sales_value / NULLIF(units_sold, 0), 2)
        AS revenue_per_unit,
    ROUND(
        100.0 * (
            sales_value - LAG(sales_value) OVER (ORDER BY invoice_month)
        ) / NULLIF(
            LAG(sales_value) OVER (ORDER BY invoice_month), 0
        ),
        2
    ) AS sales_change_pct
FROM monthly
ORDER BY invoice_month;

-- Which products deserve investigation for possible cancellation or return issues?

WITH product_sales AS (
    SELECT
        stock_code,
        SUM(line_revenue) AS positive_sales_value,
        SUM(quantity) AS units_sold
    FROM retail_sales
    GROUP BY stock_code
),
product_cancellations AS (
    SELECT
        stock_code,
        SUM(ABS(quantity * unit_price)) AS cancellation_value,
        SUM(ABS(quantity)) AS cancellation_units,
        COUNT(DISTINCT invoice_no) AS cancellation_invoices
    FROM retail_transactions
    WHERE LEFT(UPPER(TRIM(invoice_no)), 1) = 'C'
    GROUP BY stock_code
)
SELECT
    COALESCE(s.stock_code, c.stock_code) AS stock_code,
    s.positive_sales_value,
    c.cancellation_value,
    s.units_sold,
    c.cancellation_units,
    c.cancellation_invoices,
    ROUND(
        100.0 * c.cancellation_value
        / NULLIF(s.positive_sales_value, 0),
        2
    ) AS cancellation_value_to_sales_pct
FROM product_sales s
FULL OUTER JOIN product_cancellations c USING (stock_code)
WHERE c.cancellation_value IS NOT NULL
ORDER BY cancellation_value_to_sales_pct DESC NULLS FIRST;

-- What percentage of sales comes from the highest-selling products?

WITH product_sales AS (
    SELECT
        stock_code,
        MAX(description) AS description,
        SUM(line_revenue) AS sales_value
    FROM retail_sales
    GROUP BY stock_code
),
ranked AS (
    SELECT
        *,
        SUM(sales_value) OVER (
            ORDER BY sales_value DESC, stock_code
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_sales,
        SUM(sales_value) OVER () AS total_sales
    FROM product_sales
)
SELECT
    stock_code,
    description,
    ROUND(sales_value, 2) AS sales_value,
    ROUND(100.0 * sales_value / NULLIF(total_sales, 0), 2)
        AS product_sales_pct,
    ROUND(100.0 * cumulative_sales / NULLIF(total_sales, 0), 2)
        AS cumulative_sales_pct
FROM ranked
ORDER BY sales_value DESC;

-- Which weekdays and hours generate the most sales?

SELECT
    EXTRACT(ISODOW FROM invoice_date)::integer AS weekday_number,
    TO_CHAR(invoice_date, 'Dy') AS weekday,
    EXTRACT(HOUR FROM invoice_date)::integer AS hour_of_day,
    COUNT(DISTINCT invoice_no) AS orders,
    SUM(line_revenue) AS sales_value,
    SUM(quantity) AS units_sold
FROM retail_sales
GROUP BY
    EXTRACT(ISODOW FROM invoice_date),
    TO_CHAR(invoice_date, 'Dy'),
    EXTRACT(HOUR FROM invoice_date)
ORDER BY weekday_number, hour_of_day;

-- How long does it take a customer to return after their first observed purchase?

WITH customer_orders AS (
    SELECT
        customer_id,
        invoice_no,
        MIN(invoice_date) AS order_date
    FROM retail_sales
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id, invoice_no
),
numbered_orders AS (
    SELECT
        customer_id,
        order_date,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY order_date, invoice_no
        ) AS order_number
    FROM customer_orders
),
first_two AS (
    SELECT
        customer_id,
        MAX(order_date) FILTER (WHERE order_number = 1) AS first_order,
        MAX(order_date) FILTER (WHERE order_number = 2) AS second_order
    FROM numbered_orders
    WHERE order_number <= 2
    GROUP BY customer_id
)
SELECT
    COUNT(*) FILTER (WHERE second_order IS NOT NULL)
        AS customers_with_second_order,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (second_order - first_order)) / 86400.0)
            FILTER (WHERE second_order IS NOT NULL)::numeric,
        1
    ) AS avg_days_to_second_order,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE second_order < first_order + INTERVAL '30 days'
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_customers_returning_within_30_days,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE second_order < first_order + INTERVAL '90 days'
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_customers_returning_within_90_days
FROM first_two;