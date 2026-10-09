#!/bin/bash
# Destroy the aurora_analytics / pg_clickhouse lab, including the S3 bucket and its data.
#   ./destroy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform is not installed"
[ -d .terraform ] || die "terraform is not initialised here (run ./deploy.sh or terraform init first)"

BUCKET=$(terraform output -raw bucket 2>/dev/null || true)
if [ -z "$BUCKET" ] && [ -f config.env ]; then
  BUCKET=$(grep -E '^BUCKET=' config.env | head -1 | cut -d= -f2- || true)
fi
[ -n "$BUCKET" ] || die "no bucket in the Terraform state or config.env: nothing to destroy (or the state is elsewhere)"

echo "This destroys the whole lab: Aurora, both EC2s, the VPC and the S3 bucket."
echo "The bucket is emptied and deleted with everything in it (TPC-DS data included):"
echo
echo "  $BUCKET"
echo
read -r -p "Type the bucket name to continue: " TYPED
[ "$TYPED" = "$BUCKET" ] || die "name does not match, nothing destroyed"

# Terraform asks for its own confirmation
terraform destroy

if [ -f config.env ]; then
  DEST="config.env.destroyed-$(date +%Y%m%d-%H%M%S)"
  mv config.env "$DEST"
  echo "config.env renamed to $DEST (gitignored; it still holds the generated passwords, delete it when done)"
fi
