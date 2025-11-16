#!/usr/bin/env python3
"""
Create a real Apache Iceberg table for ClickHouse Cloud testing
Uses PyIceberg to create proper Iceberg table with snapshots
"""

import sys
import subprocess
import os
from datetime import datetime, date

# Check and install required packages
def install_package(package):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", package])

try:
    import pandas as pd
    import pyarrow as pa
    from pyiceberg.catalog import load_catalog
    from pyiceberg.schema import Schema
    from pyiceberg.types import NestedField, StringType, LongType, DoubleType, DateType
    from pyiceberg.partitioning import PartitionSpec, PartitionField
    from pyiceberg.transforms import IdentityTransform
except ImportError:
    print("Installing required packages...")
    install_package("pandas")
    install_package("pyarrow")
    install_package("boto3")
    install_package("pyiceberg[s3fs,glue]")
    import pandas as pd
    import pyarrow as pa
    from pyiceberg.catalog import load_catalog
    from pyiceberg.schema import Schema
    from pyiceberg.types import NestedField, StringType, LongType, DoubleType, DateType
    from pyiceberg.partitioning import PartitionSpec, PartitionField
    from pyiceberg.transforms import IdentityTransform

def get_terraform_output(key):
    """Get value from terraform output"""
    result = subprocess.run(
        ["terraform", "output", "-raw", key],
        capture_output=True,
        text=True,
        cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    return result.stdout.strip() if result.returncode == 0 else None

def create_sample_data():
    """Create sample sales data with proper schema"""
    # Define PyArrow schema matching Iceberg schema
    schema = pa.schema([
        pa.field('id', pa.int64(), nullable=False),
        pa.field('user_id', pa.string(), nullable=False),
        pa.field('product_id', pa.string(), nullable=False),
        pa.field('category', pa.string(), nullable=False),
        pa.field('quantity', pa.int64(), nullable=False),
        pa.field('price', pa.float64(), nullable=False),
        pa.field('order_date', pa.date32(), nullable=False),
        pa.field('description', pa.string(), nullable=True),
    ])

    data = {
        'id': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        'user_id': ['user_1', 'user_2', 'user_3', 'user_4', 'user_5',
                    'user_1', 'user_2', 'user_3', 'user_4', 'user_5'],
        'product_id': ['prod_1', 'prod_2', 'prod_3', 'prod_4', 'prod_5',
                       'prod_2', 'prod_1', 'prod_5', 'prod_3', 'prod_4'],
        'category': ['Electronics', 'Books', 'Clothing', 'Food', 'Sports',
                     'Books', 'Electronics', 'Sports', 'Clothing', 'Food'],
        'quantity': [5, 2, 1, 10, 3, 1, 2, 1, 2, 5],
        'price': [99.99, 29.99, 49.99, 9.99, 79.99,
                  29.99, 99.99, 79.99, 49.99, 9.99],
        'order_date': [date(2024, 1, 1), date(2024, 1, 1), date(2024, 1, 1), date(2024, 1, 1), date(2024, 1, 1),
                       date(2024, 1, 2), date(2024, 1, 2), date(2024, 1, 2), date(2024, 1, 2), date(2024, 1, 2)],
        'description': [
            'High-quality headphones', 'Programming guide book', 'Winter jacket',
            'Organic coffee beans', 'Yoga mat set', 'Programming guide book',
            'High-quality headphones', 'Yoga mat set', 'Winter jacket', 'Organic coffee beans'
        ]
    }
    return pa.Table.from_pydict(data, schema=schema)

def create_iceberg_table_with_pyiceberg(s3_bucket, glue_database, aws_region):
    """Create Iceberg table using PyIceberg with Glue catalog"""

    print(f"Creating Iceberg table in Glue catalog: {glue_database}")
    print(f"S3 Location: s3://{s3_bucket}/iceberg/sales_orders/")

    # Configure Glue catalog
    catalog = load_catalog(
        "glue",
        **{
            "type": "glue",
            "s3.region": aws_region,
            "glue.region": aws_region,
        }
    )

    # Define schema
    schema = Schema(
        NestedField(field_id=1, name="id", field_type=LongType(), required=True),
        NestedField(field_id=2, name="user_id", field_type=StringType(), required=True),
        NestedField(field_id=3, name="product_id", field_type=StringType(), required=True),
        NestedField(field_id=4, name="category", field_type=StringType(), required=True),
        NestedField(field_id=5, name="quantity", field_type=LongType(), required=True),
        NestedField(field_id=6, name="price", field_type=DoubleType(), required=True),
        NestedField(field_id=7, name="order_date", field_type=DateType(), required=True),
        NestedField(field_id=8, name="description", field_type=StringType(), required=False),
    )

    # Define partition spec (partition by order_date)
    partition_spec = PartitionSpec(
        PartitionField(source_id=7, field_id=1000, transform=IdentityTransform(), name="order_date")
    )

    # Table location
    table_location = f"s3://{s3_bucket}/iceberg/sales_orders"

    try:
        # Try to drop existing table
        try:
            catalog.drop_table(f"{glue_database}.sales_orders")
            print("  Dropped existing table")
        except:
            pass

        # Create table
        table = catalog.create_table(
            identifier=f"{glue_database}.sales_orders",
            schema=schema,
            location=table_location,
            partition_spec=partition_spec,
            properties={
                "write.format.default": "parquet",
                "write.metadata.compression-codec": "gzip"
            }
        )
        print(f"  ✓ Created Iceberg table: {glue_database}.sales_orders")

        # Create sample data
        print("  Creating sample data...")
        arrow_table = create_sample_data()
        print(f"  ✓ Generated {len(arrow_table)} records")

        # Write data to table
        print("  Writing data to Iceberg table...")
        table.append(arrow_table)
        print(f"  ✓ Data written successfully")

        # Verify snapshot
        metadata = table.metadata
        if metadata.current_snapshot_id:
            print(f"  ✓ Snapshot created: {metadata.current_snapshot_id}")

        return table_location

    except Exception as e:
        print(f"  ✗ Error creating table: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

def main():
    print("=" * 60)
    print("Create Iceberg Table for ClickHouse Cloud")
    print("=" * 60)
    print()

    # Get configuration from Terraform
    s3_bucket = get_terraform_output("s3_bucket_name")
    glue_database = get_terraform_output("glue_database_name")
    aws_region = get_terraform_output("aws_region")

    if not s3_bucket or not glue_database or not aws_region:
        print("ERROR: Could not get configuration from Terraform")
        print("Make sure you have run 'terraform apply' first")
        sys.exit(1)

    print(f"S3 Bucket: {s3_bucket}")
    print(f"Glue Database: {glue_database}")
    print(f"AWS Region: {aws_region}")
    print()

    # Create Iceberg table using PyIceberg
    table_location = create_iceberg_table_with_pyiceberg(s3_bucket, glue_database, aws_region)

    print()
    print("=" * 60)
    print("✓ Iceberg Table Created Successfully!")
    print("=" * 60)
    print()
    print(f"Table Location: {table_location}")
    print()
    print("Next steps:")
    print("1. Table is already registered in Glue catalog - no crawler needed!")
    print()
    print("2. Test in ClickHouse Cloud with DataLakeCatalog:")
    print(f"   CREATE DATABASE glue_db")
    print(f"   ENGINE = DataLakeCatalog")
    print(f"   SETTINGS")
    print(f"       catalog_type = 'glue',")
    print(f"    -- glue_database = '{glue_database}', -- Not supported in ClickHouse 25.8")
    print(f"       region = '{aws_region}',")
    print(f"       aws_access_key_id = '$AWS_ACCESS_KEY_ID',")
    print(f"       aws_secret_access_key = '$AWS_SECRET_ACCESS_KEY';")
    print()
    print(f"   -- List all tables")
    print(f"   SHOW TABLES FROM glue_db;")
    print()
    print(f"   -- Query the Iceberg table")
    print(f"   SELECT * FROM glue_db.sales_orders LIMIT 10;")
    print()

if __name__ == "__main__":
    main()
