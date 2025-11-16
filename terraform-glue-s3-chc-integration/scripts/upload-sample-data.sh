#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Header
echo ""
echo "=========================================="
echo "   Sample Data Upload Script"
echo "=========================================="
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SAMPLE_DATA_DIR="$PROJECT_DIR/sample-data"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command_exists aws; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

print_success "AWS CLI found: $(aws --version | cut -d' ' -f1)"

if ! command_exists terraform; then
    print_error "Terraform is not installed. Please install it first."
    exit 1
fi

print_success "Terraform found: $(terraform version | head -n 1)"

if ! command_exists python3; then
    print_error "Python 3 is not installed. Please install it first."
    exit 1
fi

print_success "Python 3 found: $(python3 --version)"

echo ""

# Check if Terraform has been applied
print_info "Checking Terraform state..."

cd "$PROJECT_DIR"

if [ ! -f "terraform.tfstate" ]; then
    print_error "Terraform state not found. Please run 'terraform apply' first."
    exit 1
fi

# Get S3 bucket name from Terraform output
S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null)

if [ -z "$S3_BUCKET" ]; then
    print_error "Could not get S3 bucket name from Terraform output."
    print_info "Make sure you have run 'terraform apply' successfully."
    exit 1
fi

print_success "Found S3 bucket: $S3_BUCKET"

# Get AWS region
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null)
print_success "AWS Region: $AWS_REGION"

echo ""

# Check if sample data exists
if [ ! -d "$SAMPLE_DATA_DIR" ]; then
    print_warning "Sample data directory not found: $SAMPLE_DATA_DIR"
    echo ""
    read -p "Generate sample data now? (yes/no): " generate_choice

    if [ "$generate_choice" == "yes" ]; then
        print_info "Generating sample data..."

        # Check if required Python packages are installed
        if ! python3 -c "import pandas, pyarrow" 2>/dev/null; then
            print_warning "Required Python packages not found."
            print_info "Installing required packages..."
            pip3 install pandas pyarrow pyiceberg || {
                print_error "Failed to install required packages."
                print_info "Please install manually: pip3 install pandas pyarrow pyiceberg"
                exit 1
            }
        fi

        "$SCRIPT_DIR/generate-sample-data.py"

        if [ $? -eq 0 ]; then
            print_success "Sample data generated successfully"
        else
            print_error "Failed to generate sample data"
            exit 1
        fi
    else
        print_info "Exiting. Please generate sample data first using:"
        print_info "  ./scripts/generate-sample-data.py"
        exit 0
    fi
fi

echo ""
echo "=========================================="
echo "  Uploading Sample Data to S3"
echo "=========================================="
echo ""

# Upload CSV files
if [ -d "$SAMPLE_DATA_DIR/csv" ]; then
    print_info "Uploading CSV files..."
    aws s3 sync "$SAMPLE_DATA_DIR/csv/" "s3://$S3_BUCKET/csv/" \
        --region "$AWS_REGION" \
        --exclude ".*" \
        --exclude "*.md"
    print_success "CSV files uploaded"
fi

# Upload Parquet files
if [ -d "$SAMPLE_DATA_DIR/parquet" ]; then
    print_info "Uploading Parquet files..."
    aws s3 sync "$SAMPLE_DATA_DIR/parquet/" "s3://$S3_BUCKET/parquet/" \
        --region "$AWS_REGION" \
        --exclude ".*" \
        --exclude "*.md"
    print_success "Parquet files uploaded"
fi

# Upload Avro files
if [ -d "$SAMPLE_DATA_DIR/avro" ]; then
    print_info "Uploading Avro files..."
    aws s3 sync "$SAMPLE_DATA_DIR/avro/" "s3://$S3_BUCKET/avro/" \
        --region "$AWS_REGION" \
        --exclude ".*" \
        --exclude "*.md"
    print_success "Avro files uploaded"
fi

# Upload Iceberg files
if [ -d "$SAMPLE_DATA_DIR/iceberg" ]; then
    print_info "Uploading Iceberg table data..."
    aws s3 sync "$SAMPLE_DATA_DIR/iceberg/" "s3://$S3_BUCKET/iceberg/" \
        --region "$AWS_REGION" \
        --exclude ".*" \
        --exclude "*.md"
    print_success "Iceberg files uploaded"
fi

echo ""
echo "=========================================="
print_success "Sample Data Upload Complete!"
echo "=========================================="
echo ""

# List uploaded files
print_info "Verifying uploads..."
echo ""
echo "CSV files:"
aws s3 ls "s3://$S3_BUCKET/csv/" --recursive --region "$AWS_REGION" | head -10

echo ""
echo "Parquet files:"
aws s3 ls "s3://$S3_BUCKET/parquet/" --recursive --region "$AWS_REGION" | head -10

echo ""
echo "Iceberg files:"
aws s3 ls "s3://$S3_BUCKET/iceberg/" --recursive --region "$AWS_REGION" | head -10

echo ""
echo "=========================================="
print_warning "Next Steps:"
echo "=========================================="
echo ""
echo "1. Run Glue Crawlers to populate the catalog:"
echo ""

# Get crawler names if available
ICEBERG_CRAWLER=$(terraform output -raw glue_crawler_names 2>/dev/null | grep -o '"iceberg":"[^"]*"' | cut -d'"' -f4)
CSV_CRAWLER=$(terraform output -raw glue_crawler_names 2>/dev/null | grep -o '"csv":"[^"]*"' | cut -d'"' -f4)
PARQUET_CRAWLER=$(terraform output -raw glue_crawler_names 2>/dev/null | grep -o '"parquet":"[^"]*"' | cut -d'"' -f4)

if [ -n "$ICEBERG_CRAWLER" ]; then
    echo "   aws glue start-crawler --name $ICEBERG_CRAWLER --region $AWS_REGION"
fi
if [ -n "$CSV_CRAWLER" ]; then
    echo "   aws glue start-crawler --name $CSV_CRAWLER --region $AWS_REGION"
fi
if [ -n "$PARQUET_CRAWLER" ]; then
    echo "   aws glue start-crawler --name $PARQUET_CRAWLER --region $AWS_REGION"
fi

echo ""
echo "2. View ClickHouse integration info:"
echo "   terraform output clickhouse_integration_info"
echo ""
echo "3. Get AWS credentials for ClickHouse:"
echo "   terraform output clickhouse_access_key_id"
echo "   terraform output -raw clickhouse_secret_access_key"
echo ""
print_success "Upload script completed!"
echo ""
