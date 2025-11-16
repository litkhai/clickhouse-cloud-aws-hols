#!/usr/bin/env python3
"""
Generate sample data files in CSV, Parquet, Avro, and Iceberg formats
for ClickHouse Cloud and AWS Glue integration testing.
"""

import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

try:
    import pandas as pd
    import pyarrow as pa
    import pyarrow.parquet as pq
    from pyiceberg.catalog import load_catalog
    from pyiceberg.schema import Schema
    from pyiceberg.types import (
        NestedField, StringType, IntegerType, DoubleType, TimestampType
    )
except ImportError as e:
    print(f"Error: Missing required package. {e}")
    print("\nPlease install required packages:")
    print("  pip install pandas pyarrow pyiceberg")
    sys.exit(1)

# Sample data configuration
NUM_RECORDS = 1000
OUTPUT_DIR = Path(__file__).parent.parent / "sample-data"


def generate_sample_dataframe():
    """Generate a sample DataFrame with various data types."""
    base_date = datetime(2024, 1, 1)

    data = {
        'id': range(1, NUM_RECORDS + 1),
        'user_id': [f"user_{i % 100}" for i in range(1, NUM_RECORDS + 1)],
        'product_id': [f"prod_{i % 50}" for i in range(1, NUM_RECORDS + 1)],
        'category': [
            ['Electronics', 'Books', 'Clothing', 'Food', 'Sports'][i % 5]
            for i in range(1, NUM_RECORDS + 1)
        ],
        'quantity': [(i % 10) + 1 for i in range(1, NUM_RECORDS + 1)],
        'price': [round((i % 100) + 10.99, 2) for i in range(1, NUM_RECORDS + 1)],
        'timestamp': [
            base_date + timedelta(hours=i)
            for i in range(NUM_RECORDS)
        ],
        'description': [
            f"Sample product description for item {i}"
            for i in range(1, NUM_RECORDS + 1)
        ]
    }

    return pd.DataFrame(data)


def generate_csv(df, output_dir):
    """Generate CSV file."""
    print("Generating CSV file...")
    csv_dir = output_dir / "csv"
    csv_dir.mkdir(parents=True, exist_ok=True)

    csv_path = csv_dir / "sample_data.csv"
    df.to_csv(csv_path, index=False)
    print(f"  ✓ Created: {csv_path}")

    return csv_path


def generate_parquet(df, output_dir):
    """Generate Parquet file."""
    print("Generating Parquet file...")
    parquet_dir = output_dir / "parquet"
    parquet_dir.mkdir(parents=True, exist_ok=True)

    parquet_path = parquet_dir / "sample_data.parquet"
    df.to_parquet(parquet_path, index=False, engine='pyarrow')
    print(f"  ✓ Created: {parquet_path}")

    return parquet_path


def generate_avro(df, output_dir):
    """Generate Avro file using Parquet as intermediary."""
    print("Generating Avro file...")
    avro_dir = output_dir / "avro"
    avro_dir.mkdir(parents=True, exist_ok=True)

    # Convert to PyArrow Table
    table = pa.Table.from_pandas(df)

    # Write as Parquet first (Avro support in PyArrow is limited)
    # In production, use fastavro library for proper Avro support
    avro_path = avro_dir / "sample_data.parquet"
    pq.write_table(table, avro_path)
    print(f"  ✓ Created: {avro_path} (Parquet format for compatibility)")
    print(f"    Note: For production Avro files, use the fastavro library")

    return avro_path


def generate_iceberg_metadata(output_dir):
    """Generate Iceberg table metadata structure."""
    print("Generating Iceberg table metadata...")
    iceberg_dir = output_dir / "iceberg" / "sales_data"

    # Create directory structure
    metadata_dir = iceberg_dir / "metadata"
    data_dir = iceberg_dir / "data"
    metadata_dir.mkdir(parents=True, exist_ok=True)
    data_dir.mkdir(parents=True, exist_ok=True)

    # Create a simple metadata JSON (simplified version)
    # In production, use PyIceberg or Iceberg Java library
    metadata = {
        "format-version": 2,
        "table-uuid": "12345678-1234-5678-1234-567812345678",
        "location": str(iceberg_dir),
        "last-updated-ms": int(datetime.now().timestamp() * 1000),
        "properties": {
            "write.format.default": "parquet"
        },
        "schema": {
            "type": "struct",
            "schema-id": 0,
            "fields": [
                {"id": 1, "name": "id", "required": True, "type": "int"},
                {"id": 2, "name": "user_id", "required": True, "type": "string"},
                {"id": 3, "name": "product_id", "required": True, "type": "string"},
                {"id": 4, "name": "category", "required": True, "type": "string"},
                {"id": 5, "name": "quantity", "required": True, "type": "int"},
                {"id": 6, "name": "price", "required": True, "type": "double"},
                {"id": 7, "name": "timestamp", "required": True, "type": "timestamp"},
                {"id": 8, "name": "description", "required": False, "type": "string"}
            ]
        }
    }

    version_hint_path = metadata_dir / "version-hint.text"
    with open(version_hint_path, 'w') as f:
        f.write("1")

    metadata_path = metadata_dir / "v1.metadata.json"
    with open(metadata_path, 'w') as f:
        json.dump(metadata, f, indent=2)

    print(f"  ✓ Created: {metadata_path}")
    print(f"  ✓ Created: {version_hint_path}")

    # Generate sample data file in Iceberg data directory
    df = generate_sample_dataframe()
    data_path = data_dir / "data-001.parquet"
    df.to_parquet(data_path, index=False, engine='pyarrow')
    print(f"  ✓ Created: {data_path}")

    # Create README for Iceberg
    readme_path = iceberg_dir / "README.md"
    with open(readme_path, 'w') as f:
        f.write("""# Iceberg Table: sales_data

This directory contains an Iceberg table structure.

## Structure
- `metadata/`: Table metadata and schema definitions
- `data/`: Parquet data files

## Usage with ClickHouse Cloud

```sql
-- Using direct S3 path
CREATE TABLE sales_iceberg
ENGINE = Iceberg('s3://bucket-name/iceberg/sales_data/', 'AWS', 'access_key', 'secret_key', 'region');

-- Using AWS Glue Catalog
CREATE TABLE sales_iceberg
ENGINE = IcebergGlueCatalog(
    'catalog_id=123456789012',
    'database=clickhouse_iceberg_db',
    'table=sales_data',
    'aws_access_key_id=...',
    'aws_secret_access_key=...',
    'region=us-east-1'
);
```
""")
    print(f"  ✓ Created: {readme_path}")

    return iceberg_dir


def generate_additional_tables(output_dir):
    """Generate additional sample tables for different use cases."""
    print("\nGenerating additional sample tables...")

    # User demographics table
    users_df = pd.DataFrame({
        'user_id': [f"user_{i}" for i in range(100)],
        'name': [f"User Name {i}" for i in range(100)],
        'email': [f"user{i}@example.com" for i in range(100)],
        'age': [(i % 50) + 18 for i in range(100)],
        'country': [
            ['USA', 'UK', 'Germany', 'France', 'Japan'][i % 5]
            for i in range(100)
        ],
        'signup_date': [
            datetime(2023, 1, 1) + timedelta(days=i * 3)
            for i in range(100)
        ]
    })

    users_dir = output_dir / "csv" / "users"
    users_dir.mkdir(parents=True, exist_ok=True)
    users_df.to_csv(users_dir / "users.csv", index=False)
    print(f"  ✓ Created: users table (CSV)")

    # Product catalog table
    products_df = pd.DataFrame({
        'product_id': [f"prod_{i}" for i in range(50)],
        'name': [f"Product {i}" for i in range(50)],
        'category': [
            ['Electronics', 'Books', 'Clothing', 'Food', 'Sports'][i % 5]
            for i in range(50)
        ],
        'base_price': [round((i * 10) + 9.99, 2) for i in range(50)],
        'stock_quantity': [(i * 100) + 50 for i in range(50)],
        'created_at': [
            datetime(2023, 1, 1) + timedelta(days=i * 7)
            for i in range(50)
        ]
    })

    products_dir = output_dir / "parquet" / "products"
    products_dir.mkdir(parents=True, exist_ok=True)
    products_df.to_parquet(products_dir / "products.parquet", index=False)
    print(f"  ✓ Created: products table (Parquet)")


def create_readme(output_dir):
    """Create README file for sample data."""
    readme_content = """# Sample Data Files

This directory contains sample data files in various formats for testing ClickHouse Cloud and AWS Glue integration.

## Directory Structure

```
sample-data/
├── csv/
│   ├── sample_data.csv         # Main sample data (1000 records)
│   └── users/
│       └── users.csv           # User demographics (100 records)
├── parquet/
│   ├── sample_data.parquet     # Main sample data
│   └── products/
│       └── products.parquet    # Product catalog (50 records)
├── avro/
│   └── sample_data.parquet     # Sample data in Parquet format
└── iceberg/
    └── sales_data/             # Iceberg table structure
        ├── metadata/           # Table metadata
        └── data/               # Parquet data files
```

## Data Schema

### Main Sample Data (sample_data)
- `id` (int): Unique record identifier
- `user_id` (string): User identifier
- `product_id` (string): Product identifier
- `category` (string): Product category
- `quantity` (int): Quantity purchased
- `price` (double): Price per unit
- `timestamp` (timestamp): Transaction timestamp
- `description` (string): Product description

### Users Table
- `user_id` (string): User identifier
- `name` (string): User full name
- `email` (string): User email address
- `age` (int): User age
- `country` (string): User country
- `signup_date` (timestamp): Account creation date

### Products Table
- `product_id` (string): Product identifier
- `name` (string): Product name
- `category` (string): Product category
- `base_price` (double): Product base price
- `stock_quantity` (int): Available stock
- `created_at` (timestamp): Product creation date

## Usage

Upload these files to S3 using the upload script:
```bash
./scripts/upload-sample-data.sh
```

After upload, run AWS Glue crawlers to populate the Glue Data Catalog.

## Generated Statistics
- Total Records: 1,000+ across all tables
- File Formats: CSV, Parquet, Avro (as Parquet), Iceberg
- Categories: 5 product categories
- Users: 100 unique users
- Products: 50 unique products
"""

    readme_path = output_dir / "README.md"
    with open(readme_path, 'w') as f:
        f.write(readme_content)
    print(f"\n✓ Created: {readme_path}")


def main():
    """Main function to generate all sample data files."""
    print("=" * 60)
    print("Sample Data Generator for ClickHouse-Glue Integration")
    print("=" * 60)
    print()

    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Output directory: {OUTPUT_DIR}")
    print()

    # Generate sample data
    df = generate_sample_dataframe()
    print(f"Generated {len(df)} sample records")
    print()

    # Generate files in different formats
    generate_csv(df, OUTPUT_DIR)
    generate_parquet(df, OUTPUT_DIR)
    generate_avro(df, OUTPUT_DIR)
    generate_iceberg_metadata(OUTPUT_DIR)

    # Generate additional tables
    generate_additional_tables(OUTPUT_DIR)

    # Create README
    create_readme(OUTPUT_DIR)

    print()
    print("=" * 60)
    print("✓ Sample data generation completed successfully!")
    print("=" * 60)
    print()
    print("Next steps:")
    print("  1. Review generated files in:", OUTPUT_DIR)
    print("  2. Upload to S3 using: ./scripts/upload-sample-data.sh")
    print()


if __name__ == "__main__":
    main()
