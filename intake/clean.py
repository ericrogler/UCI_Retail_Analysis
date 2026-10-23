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