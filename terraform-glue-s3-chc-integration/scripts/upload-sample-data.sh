#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo ""
echo "=========================================="
echo "   Sample Data Upload & Setup Script"
echo "=========================================="
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Get S3 bucket and region from Terraform
print_info "Getting configuration from Terraform..."
S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null)

if [ -z "$S3_BUCKET" ]; then
    print_error "Could not get S3 bucket from Terraform output"
    exit 1
fi

print_success "S3 Bucket: $S3_BUCKET"
print_success "Region: $AWS_REGION"

echo ""
print_info "Creating sample data files locally..."

# Create sample-data directory
mkdir -p sample-data/{csv,parquet,avro,iceberg/sales_data/{metadata,data}}

# Generate simple CSV file
print_info "Generating CSV sample data..."
cat > sample-data/csv/sales_data.csv << 'EOF'
id,user_id,product_id,category,quantity,price,timestamp,description
1,user_1,prod_1,Electronics,5,99.99,2024-01-01 10:00:00,High-quality headphones
2,user_2,prod_2,Books,2,29.99,2024-01-01 11:30:00,Programming guide book
3,user_3,prod_3,Clothing,1,49.99,2024-01-01 12:15:00,Winter jacket
4,user_4,prod_4,Food,10,9.99,2024-01-01 13:45:00,Organic coffee beans
5,user_5,prod_5,Sports,3,79.99,2024-01-01 14:20:00,Yoga mat set
6,user_1,prod_2,Books,1,29.99,2024-01-02 09:00:00,Programming guide book
7,user_2,prod_1,Electronics,2,99.99,2024-01-02 10:30:00,High-quality headphones
8,user_3,prod_5,Sports,1,79.99,2024-01-02 11:15:00,Yoga mat set
9,user_4,prod_3,Clothing,2,49.99,2024-01-02 12:45:00,Winter jacket
10,user_5,prod_4,Food,5,9.99,2024-01-02 13:30:00,Organic coffee beans
EOF

print_success "Created CSV file: sample-data/csv/sales_data.csv"

# Generate users CSV
cat > sample-data/csv/users.csv << 'EOF'
user_id,name,email,age,country,signup_date
user_1,John Doe,john@example.com,28,USA,2023-01-15
user_2,Jane Smith,jane@example.com,35,UK,2023-02-20
user_3,Bob Johnson,bob@example.com,42,Germany,2023-03-10
user_4,Alice Brown,alice@example.com,31,France,2023-04-05
user_5,Charlie Wilson,charlie@example.com,26,Japan,2023-05-12
EOF

print_success "Created users CSV: sample-data/csv/users.csv"

# Generate products CSV (for Parquet conversion later)
cat > sample-data/parquet/products.csv << 'EOF'
product_id,name,category,base_price,stock_quantity,created_at
prod_1,Wireless Headphones,Electronics,99.99,150,2023-01-01
prod_2,Python Programming Book,Books,29.99,200,2023-01-01
prod_3,Winter Jacket,Clothing,49.99,100,2023-01-01
prod_4,Organic Coffee,Food,9.99,500,2023-01-01
prod_5,Yoga Mat Set,Sports,79.99,75,2023-01-01
EOF

print_success "Created products CSV: sample-data/parquet/products.csv"

# Create a simple Iceberg metadata structure
cat > sample-data/iceberg/sales_data/metadata/version-hint.text << 'EOF'
1
EOF

cat > sample-data/iceberg/sales_data/metadata/v1.metadata.json << 'EOF'
{
  "format-version": 2,
  "table-uuid": "12345678-1234-5678-1234-567812345678",
  "location": "s3://BUCKET_NAME/iceberg/sales_data/",
  "last-updated-ms": 1704067200000,
  "properties": {
    "write.format.default": "parquet"
  },
  "schema": {
    "type": "struct",
    "schema-id": 0,
    "fields": [
      {"id": 1, "name": "id", "required": true, "type": "int"},
      {"id": 2, "name": "user_id", "required": true, "type": "string"},
      {"id": 3, "name": "product_id", "required": true, "type": "string"},
      {"id": 4, "name": "category", "required": true, "type": "string"},
      {"id": 5, "name": "quantity", "required": true, "type": "int"},
      {"id": 6, "name": "price", "required": true, "type": "double"},
      {"id": 7, "name": "timestamp", "required": true, "type": "string"},
      {"id": 8, "name": "description", "required": false, "type": "string"}
    ]
  }
}
EOF

# Copy CSV to iceberg data folder as well
cp sample-data/csv/sales_data.csv sample-data/iceberg/sales_data/data/

print_success "Created Iceberg metadata structure"

echo ""
print_info "Uploading files to S3..."

# Upload CSV files
aws s3 cp sample-data/csv/ "s3://$S3_BUCKET/csv/" --recursive --region "$AWS_REGION"
print_success "Uploaded CSV files"

# Upload Parquet files
aws s3 cp sample-data/parquet/ "s3://$S3_BUCKET/parquet/" --recursive --region "$AWS_REGION"
print_success "Uploaded Parquet files"

# Upload Iceberg files
aws s3 cp sample-data/iceberg/ "s3://$S3_BUCKET/iceberg/" --recursive --region "$AWS_REGION"
print_success "Uploaded Iceberg files"

echo ""
print_info "Verifying uploads..."
aws s3 ls "s3://$S3_BUCKET/" --recursive --region "$AWS_REGION" | grep -E "\.(csv|json|text)$"

echo ""
print_info "Starting Glue Crawlers..."

# Get crawler names
ICEBERG_CRAWLER=$(terraform output -json glue_crawler_names 2>/dev/null | grep -o '"iceberg":"[^"]*"' | cut -d'"' -f4)
CSV_CRAWLER=$(terraform output -json glue_crawler_names 2>/dev/null | grep -o '"csv":"[^"]*"' | cut -d'"' -f4)
PARQUET_CRAWLER=$(terraform output -json glue_crawler_names 2>/dev/null | grep -o '"parquet":"[^"]*"' | cut -d'"' -f4)

# Start crawlers
if [ -n "$CSV_CRAWLER" ]; then
    print_info "Starting CSV crawler: $CSV_CRAWLER"
    aws glue start-crawler --name "$CSV_CRAWLER" --region "$AWS_REGION" 2>&1 | grep -v "CrawlerRunningException" || true
    print_success "CSV crawler started"
fi

if [ -n "$PARQUET_CRAWLER" ]; then
    print_info "Starting Parquet crawler: $PARQUET_CRAWLER"
    aws glue start-crawler --name "$PARQUET_CRAWLER" --region "$AWS_REGION" 2>&1 | grep -v "CrawlerRunningException" || true
    print_success "Parquet crawler started"
fi

if [ -n "$ICEBERG_CRAWLER" ]; then
    print_info "Starting Iceberg crawler: $ICEBERG_CRAWLER"
    aws glue start-crawler --name "$ICEBERG_CRAWLER" --region "$AWS_REGION" 2>&1 | grep -v "CrawlerRunningException" || true
    print_success "Iceberg crawler started"
fi

echo ""
print_info "Waiting for crawlers to complete (this may take 2-5 minutes)..."

# Function to check crawler status
check_crawler_status() {
    local crawler_name=$1
    local status=$(aws glue get-crawler --name "$crawler_name" --region "$AWS_REGION" --query 'Crawler.State' --output text 2>/dev/null)
    echo "$status"
}

# Wait for all crawlers to finish
WAIT_TIME=0
MAX_WAIT=300  # 5 minutes

while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    ALL_READY=true

    for crawler in "$CSV_CRAWLER" "$PARQUET_CRAWLER" "$ICEBERG_CRAWLER"; do
        if [ -n "$crawler" ]; then
            status=$(check_crawler_status "$crawler")
            if [ "$status" = "RUNNING" ]; then
                ALL_READY=false
                break
            fi
        fi
    done

    if [ "$ALL_READY" = true ]; then
        break
    fi

    echo -n "."
    sleep 10
    WAIT_TIME=$((WAIT_TIME + 10))
done

echo ""

if [ $WAIT_TIME -ge $MAX_WAIT ]; then
    print_error "Timeout waiting for crawlers. Check status manually."
else
    print_success "All crawlers completed!"
fi

echo ""
print_info "Checking Glue Catalog tables..."

DATABASE_NAME=$(terraform output -raw glue_database_name 2>/dev/null)
TABLES=$(aws glue get-tables --database-name "$DATABASE_NAME" --region "$AWS_REGION" --query 'TableList[].Name' --output text 2>/dev/null)

if [ -z "$TABLES" ]; then
    print_error "No tables found in Glue Catalog yet"
    echo ""
    echo "Check crawler status manually:"
    echo "  aws glue get-crawler --name $CSV_CRAWLER"
else
    print_success "Tables found in Glue Catalog:"
    for table in $TABLES; do
        echo "  - $table"
    done
fi

echo ""
echo "=========================================="
print_success "Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. View tables: aws glue get-tables --database-name $DATABASE_NAME"
echo "  2. Test in ClickHouse Cloud:"
echo ""
echo "     SELECT * FROM s3('s3://$S3_BUCKET/csv/sales_data.csv', 'CSV') LIMIT 10;"
echo ""
