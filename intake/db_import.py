# Through Bash / PS / Command Prompt (Admin)
# pip install pandas pyarrow sqlalchemy "psycopg[binary]" dotenv

from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, BigInteger, Integer, Numeric, Text, DateTime
from sqlalchemy.engine import URL

import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# Credentials
PARQUET_PATH = Path("data/clean/retail.parquet")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_HOST = os.getenv("DB_HOST")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME")

# Connect to PostgreSQL
url = URL.create(
    "postgresql+psycopg",
    username=DB_USER,
    password=DB_PASSWORD,
    host=DB_HOST,
    port=DB_PORT,
    database=DB_NAME,
)
engine = create_engine(url)

# Read Parquet and define column names
df = pd.read_parquet(PARQUET_PATH)

column_map = {
    "InvoiceNo": "invoice_no",
    "StockCode": "stock_code",
    "Description": "description",
    "Quantity": "quantity",
    "InvoiceDate": "invoice_date",
    "UnitPrice": "unit_price",
    "CustomerID": "customer_id",
    "Country": "country",
}
df = df.rename(columns=column_map)

# Keep the source transaction fields
columns = list(column_map.values())
df = df[columns]

df["invoice_no"] = df["invoice_no"].astype("string")
df["stock_code"] = df["stock_code"].astype("string")
df["description"] = df["description"].astype("string")
df["country"] = df["country"].astype("string")
df["invoice_date"] = pd.to_datetime(df["invoice_date"])
df["quantity"] = pd.to_numeric(df["quantity"], errors="raise").astype("int64")
df["unit_price"] = pd.to_numeric(df["unit_price"], errors="raise")
df["customer_id"] = pd.to_numeric(
    df["customer_id"], errors="coerce"
).astype("Int64")
# Derived columns
df["revenue"] = df["quantity"] * df["unit_price"]

# Load into PostgreSQL & prioritize fail rather than overwrite if existing
df.to_sql(
    "retail_transactions",
    engine,
    if_exists="fail",
    index=False,
    chunksize=10_000,
    dtype={
        "invoice_no": Text(),
        "stock_code": Text(),
        "description": Text(),
        "quantity": Integer(),
        "invoice_date": DateTime(),
        "unit_price": Numeric(12, 4),
        "customer_id": BigInteger(),
        "country": Text(),
        "revenue": Numeric(14, 4),
    },
)

print(f"Imported {len(df):,} rows.")
