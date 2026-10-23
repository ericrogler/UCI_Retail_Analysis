# Retail Revenue & Customer Analytics

Author: Eric Rogler
Date: October 22, 2026

As someone who worked in retail for years before, I figured I'd try out this kind of project.

The data comes from the UCI Online Retail dataset. Reference here:

```Chen, D. (2015). Online Retail [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5BW33.```

## Overview

Our goal is to answer several questions, including:
- What are customers purchasing?
- What are the habits of repeat customers?
- How well do certain products perform in our lineup?
- What are our sales over a given period of time?
- Can we determine cohorts from our customer base?

To start, rather than import the dataset directly into PowerBI or Tableau, I started with Python to clean and convert the dataset into a parquet file type (you'll see why later!) and stored in a PostgreSQL database. From there, the "cleaned" data is analyzed with SQL and divided across different views better suited for visualization. Finally, dashboards and charts are created to showcase findings and make it easy on the eyes for our would-be readers.

This setup scales better rather than direct imports in case future files are too large or cumbersome for rudimentary processing.

## Cleaning & Importing

One assumption I made is our dataset was only somewhat clean going in. It was in a standardized format, but the column names and data types (e.g. string, integer, etc.) were *not* already set.

The code is relatively short for this part:

```python
# Fast Extract & Transform
import pandas as pd
from pathlib import Path

# Load
df = pd.read_excel("data/dirty/Online Retail.xlsx")

# Standardize headers (remove accidental spaces)
df.columns = df.columns.str.strip()

# Erase duplicates
df = df.drop_duplicates()

# Data type conversion
df["InvoiceDate"] = pd.to_datetime(df["InvoiceDate"])
df["CustomerID"] = df["CustomerID"].astype("Int64")
df["InvoiceNo"] = df["InvoiceNo"].astype("string")
df["StockCode"] = df["StockCode"].astype("string")
df["Description"] = df["Description"].astype("string")

# Derived columns
df["Revenue"] = df["Quantity"] * df["UnitPrice"]

# Inspect data quality
print("Dataset shape:", df.shape)
print("\nMissing values:\n", df.isna().sum())
print("\nNegative quantities:", (df["Quantity"] < 0).sum())
print("Nonpositive prices:", (df["UnitPrice"] <= 0).sum())

# Save processed dataset
output_path = Path("data/clean/retail.parquet")
output_path.parent.mkdir(parents=True, exist_ok=True)

df.to_parquet(output_path, index=False)

print(f"Saved {len(df):,} rows to {output_path.resolve()}")
```

The inspect data quality section describes what type of data is present *before* file transformation. Doing a similar check at each stage helps with debugging in the future.

There are several reasons why I went with a parquet file for the database:
1. We're dealing with OLAP and prioritizing handling read-many, write-once scenarios
2. Open source technology avoiding vendor lock-in should we change tooling in the future.
3. A surprisingly small file size!
    - For example, this script converted a 23 MB .xlsx file down into a ~4MB .parquet file! That's around a 75% decrease.

After converting the file comes importing it into the database. This involves several steps:
1. Setting up a database with pgAdmin 4
    - Basically defining a username, password, port, database name, and etc. in the setup wizard. Nothing too fancy here.
2. Setting up an .env file to "securely" store credentials, such as usernames, passwords, etc. for this process and a .gitignore file when code's pushed to a source control platform.
2. Reading the parquet file
3. Mapping & renaming the columns (e.g. "InvoiceNo" -> "invoice_no")
4. Explicitly defining data types of each column going into the database

On "success" it returns the number of rows we imported; a value we can confirm against our data quality check in a previous stage.

## SQL / Database Stage

For this part, I used DBeaver to peer inside and manipulate my SQL databases.

Before answering any business questions, I have one more check to ensure nothing weird happened during the data import. In SQL, this is mostly COUNT() & FILTER commands, such as:

```sql
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE customer_id IS NULL)
        AS missing_customer_id,
    ...
FROM retail_transactions
```

I also thought there may've been a table I'll use quite frequently, so I'll establish it as a separate view for CTES, subqueries, and queries. It takes the data I already imported, but adds a revenue value for each line item and explicitly defines the *month* it's billed in an invoice.

```sql
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
```

From there, I looked into various areas to start, such as:
- Top 10 products (by sales)
- Monthly sales performance
- Best country
- Repeat Customers
- Customer Cohorts
- Cancellations on orders/invoices
- RFM customer segmentation (Recency, Frequency, and Monetary)

Once those questions are answered, SQL can solve more complicated questions, such as:

```sql
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
```

![Sales Value Changes based on variables](https://i.imgur.com/eaJB0hN.png)

A full list of "analysis" queries is inside a single SQL file, as you can query parts of it at a time.

## Creating Views for Visualization

Views are similar to our analysis queries and *mostly* copy-pasting what we've wrote before. I prioritize making *views* over tables for several reasons:
1. Ease of use
2. Can be cached and act as a subset of data for referencing
3. Security to allow other users to only access the parts of data I'm fine with them accessing.

For example, if I want a view for product performance, I take the CTE from my earlier analysis query to find the Top 10 Products and set it up like this:

```sql
CREATE OR REPLACE VIEW product_sales AS -- only part that changes is this line!
SELECT
    stock_code,
    MAX(description) AS description,
    SUM(quantity) AS units_sold,
    SUM(line_revenue) AS sales_value,
    COUNT(DISTINCT invoice_no) AS sales_invoices
FROM retail_sales
GROUP BY stock_code;
```

And now I have a view where all the products can be visualized and answer many other questions, such as Top 5, top 25, top 50, and top 100 instead of only top 10 like my initial inquiry.

Some views may need more adjustments, like adding another column or converting nearly the entire query from before into a separate view.

Following a similar process, multiple views are created:
- Retail Sales (the base used from earlier for queries)
- Monthly Sales
- Product Performance
- Country Performance
- Customer Metrics
- Cancellation Activity by Month
- Customer Cohort Retention

## Visualizations

For this part, I'm using PowerBI as my primary tool.

Connecting to the PostgreSQL database requires several credentials
- Server
- Database name
- Username
- Password

These bits are stored within the .env file, but also available to find within pgAdmin 4. In this particular database, the port number is different from the oft-default 5432 port, so port is specified next to server like so: "Server:Port". After connection is secure, we import all of our views and the original table.

Dashboards were split into two parts: Revenue Overview and Customer Overview

Revenue Overview contains the following information:
- Revenue by Month (in a given year)
- Top 10 Countries by Sales
- Top 10 Products by Sales

![Revenue Overview](https://i.imgur.com/Spd43xL.png)

Customer Overview contains the following information:
- Days between Orders (Recency)
- Revenue by Customer Segment
- Types of Customers & Count

![Customer Overview](https://i.imgur.com/ubey78d.png)

These should answer the preliminary questions of a potential reader about how sales are doing seasonally, what and where sells well, and a general idea of the customer base we have.

## Further Questions

Some questions may be answered directly with specific SQL queries rather than going through the trouble of setting up a dashboard for it. These include the following (with some code snippets):

```sql
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
```
![Results for Percentage of Sales](https://i.imgur.com/jaE0UKe.png)

```sql
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
```

![Weekdays (and Hour on weekday) Sales Generation](https://i.imgur.com/9Nw0T0t.png)

## Recommendations

These actionable items are based on the results of this analysis alone:
- Between the hours of 0700 to 2000, focus on orders occurring between 0900 to 1700. Have staff available to pick up "late" orders as needed between 1700-1900 on the weekdays, especially Thursday.
- You can move starting time for Sunday up to 1000 instead of 0900.
- On weekdays, starting time may go to 0800 instead of 0600 or 0700.
- Create a dedicated space for our most "popular" items customers may easily find within stores, as our top 10 items account for ~10% of all total sales.
- Majority of revenue comes from customers who are invested, make frequent orders, and spend plenty of money. As this is already a large portion of our current customer base, focus on retention and offer bonuses, discounts, promotions, and rewards for "frequent flyers" to ensure continued business.

Further recommendations would require stakeholder and operational input before proceeding with additional plans.

## Conclusion

This was a deceptively simple project, given the initial dataset and limited number of features. Nevertheless, given enough row data, even limited features can yield many insights.

Thank you for reading this.