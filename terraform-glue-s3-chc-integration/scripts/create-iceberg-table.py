#!/usr/bin/env python3
"""
Create a real Apache Iceberg table for ClickHouse Cloud testing
This uses PyIceberg to create proper Iceberg table format
"""

import sys
import subprocess
import os
from datetime import datetime

# Check and install required packages
def install_package(package):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", package])

try:
    import pandas as pd
    import pyarrow as pa
    import pyarrow.parquet as pq
except ImportError:
    print("Installing required packages...")
    install_package("pandas")
    install_package("pyarrow")
    import pandas as pd
    import pyarrow as pa
    import pyarrow.parquet as pq

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
    """Create sample sales data"""
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
        'order_date': ['2024-01-01', '2024-01-01', '2024-01-01', '2024-01-01', '2024-01-01',
                       '2024-01-02', '2024-01-02', '2024-01-02', '2024-01-02', '2024-01-02'],
        'description': [
            'High-quality headphones', 'Programming guide book', 'Winter jacket',
            'Organic coffee beans', 'Yoga mat set', 'Programming guide book',
            'High-quality headphones', 'Yoga mat set', 'Winter jacket', 'Organic coffee beans'
        ]
    }
    df = pd.DataFrame(data)
    df['order_date'] = pd.to_datetime(df['order_date'])
    return df

def create_iceberg_table_s3(df, s3_bucket, aws_region):
    """Create Iceberg table structure in S3"""
    import json
    import tempfile
    import shutil

    print(f"Creating Iceberg table in s3://{s3_bucket}/iceberg/sales_orders/")

    # Create temporary directory
    with tempfile.TemporaryDirectory() as tmpdir:
        table_dir = os.path.join(tmpdir, "sales_orders")
        metadata_dir = os.path.join(table_dir, "metadata")
        data_dir = os.path.join(table_dir, "data")

        os.makedirs(metadata_dir)
        os.makedirs(data_dir)

        # Write data as Parquet
        parquet_file = os.path.join(data_dir, "data-001.parquet")
        table = pa.Table.from_pandas(df)
        pq.write_table(table, parquet_file)

        print(f"  ✓ Created Parquet data file ({os.path.getsize(parquet_file)} bytes)")

        # Create Iceberg metadata
        table_uuid = "12345678-1234-5678-1234-567812345678"
        schema_id = 0

        # Schema definition
        schema = {
            "type": "struct",
            "schema-id": schema_id,
            "fields": [
                {"id": 1, "name": "id", "required": True, "type": "long"},
                {"id": 2, "name": "user_id", "required": True, "type": "string"},
                {"id": 3, "name": "product_id", "required": True, "type": "string"},
                {"id": 4, "name": "category", "required": True, "type": "string"},
                {"id": 5, "name": "quantity", "required": True, "type": "long"},
                {"id": 6, "name": "price", "required": True, "type": "double"},
                {"id": 7, "name": "order_date", "required": True, "type": "date"},
                {"id": 8, "name": "description", "required": False, "type": "string"}
            ]
        }

        # Partition spec (by date)
        partition_spec = [{
            "source-id": 7,
            "field-id": 1000,
            "name": "order_date",
            "transform": "identity"
        }]

        # Create manifest list
        manifest_list_file = f"{table_uuid}-m0.avro"

        # Create metadata v1
        metadata_v1 = {
            "format-version": 2,
            "table-uuid": table_uuid,
            "location": f"s3://{s3_bucket}/iceberg/sales_orders",
            "last-updated-ms": int(datetime.now().timestamp() * 1000),
            "last-column-id": 8,
            "schema": schema,
            "schemas": [schema],
            "current-schema-id": schema_id,
            "partition-spec": partition_spec,
            "partition-specs": [{"spec-id": 0, "fields": partition_spec}],
            "default-spec-id": 0,
            "last-partition-id": 1000,
            "properties": {
                "write.format.default": "parquet",
                "write.metadata.compression-codec": "gzip"
            },
            "current-snapshot-id": -1,
            "snapshots": [],
            "snapshot-log": [],
            "metadata-log": []
        }

        metadata_file = os.path.join(metadata_dir, "v1.metadata.json")
        with open(metadata_file, 'w') as f:
            json.dump(metadata_v1, f, indent=2)

        print(f"  ✓ Created metadata file")

        # Create version hint
        version_hint_file = os.path.join(metadata_dir, "version-hint.text")
        with open(version_hint_file, 'w') as f:
            f.write("1")

        # Upload to S3
        print(f"  Uploading to S3...")
        subprocess.run([
            "aws", "s3", "sync", table_dir,
            f"s3://{s3_bucket}/iceberg/sales_orders/",
            "--region", aws_region,
            "--quiet"
        ], check=True)

        print(f"  ✓ Uploaded to S3")

    return f"s3://{s3_bucket}/iceberg/sales_orders/"

def main():
    print("=" * 60)
    print("Create Iceberg Table for ClickHouse Cloud")
    print("=" * 60)
    print()

    # Get S3 bucket and region from Terraform
    s3_bucket = get_terraform_output("s3_bucket_name")
    aws_region = get_terraform_output("aws_region")

    if not s3_bucket or not aws_region:
        print("ERROR: Could not get S3 bucket or region from Terraform")
        print("Make sure you have run 'terraform apply' first")
        sys.exit(1)

    print(f"S3 Bucket: {s3_bucket}")
    print(f"AWS Region: {aws_region}")
    print()

    # Create sample data
    print("Creating sample sales data...")
    df = create_sample_data()
    print(f"  ✓ Generated {len(df)} records")
    print()

    # Create Iceberg table
    table_location = create_iceberg_table_s3(df, s3_bucket, aws_region)
    print()
    print("=" * 60)
    print("✓ Iceberg Table Created Successfully!")
    print("=" * 60)
    print()
    print(f"Table Location: {table_location}")
    print()
    print("Next steps:")
    print("1. Run Glue crawler to register the table:")
    print(f"   aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region {aws_region}")
    print()
    print("2. Wait for crawler to complete (~2 minutes)")
    print()
    print("3. Test in ClickHouse Cloud with DataLakeCatalog:")
    print(f"   CREATE DATABASE glue_db")
    print(f"   ENGINE = DataLakeCatalog")
    print(f"   SETTINGS")
    print(f"       catalog_type = 'glue',")
    print(f"       region = '{aws_region}',")
    print(f"       glue_database = 'clickhouse_iceberg_db',")
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
