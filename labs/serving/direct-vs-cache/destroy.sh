#!/bin/bash
# Destroy the AWS side: client EC2, Valkey, both DynamoDB tables, the endpoint and the bucket
# (with any results not yet fetched — run ./31-fetch.sh first).
# The ClickHouse Cloud data stays; drop it with ./90-ch-cleanup.sh after the captures.
#   ./destroy.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
cd "$LAB_DIR"

command -v terraform >/dev/null || die "terraform is not installed"
[ -d .terraform ] || die "terraform is not initialised here (run ./deploy.sh first)"
BUCKET=$(terraform output -raw bucket 2>/dev/null || true)
[ -n "$BUCKET" ] || die "no bucket in the Terraform state: nothing to destroy (or the state is elsewhere)"

echo "This destroys the client EC2, the Valkey node, both DynamoDB tables and the bucket:"
echo "  $BUCKET"
read -r -p "Type the bucket name to continue: " TYPED
[ "$TYPED" = "$BUCKET" ] || die "name does not match, nothing destroyed"

terraform destroy

if [ -f config.env ]; then
  DEST="config.env.destroyed-$(date +%Y%m%d-%H%M%S)"
  mv config.env "$DEST"
  echo "config.env renamed to $DEST"
fi
echo "Remove the client's address from the ClickHouse Cloud IP access list if you added it."
