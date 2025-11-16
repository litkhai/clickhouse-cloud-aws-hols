# Deployment Fixes and Issues Resolved

This document describes the issues encountered during deployment and their solutions.

## Issues Encountered and Fixed

### 1. Glue Crawler Schema Change Policy Error

**Error:**
```
InvalidInputException: The SchemaChangePolicy for "Crawl new folders only"
Amazon S3 target can have only LOG DeleteBehavior value and LOG UpdateBehavior value.
```

**Root Cause:**
When `recrawl_policy.recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"`, the schema change policy must use `LOG` for both `delete_behavior` and `update_behavior`.

**Fix:**
Changed `schema_change_policy` in [main.tf:174-177](main.tf#L174-L177):
```hcl
schema_change_policy {
  delete_behavior = "LOG"
  update_behavior = "LOG"  # Changed from "UPDATE_IN_DATABASE"
}
```

---

### 2. IAM User Creation Permission Error

**Error:**
```
AccessDenied: User is not authorized to perform: iam:CreateUser with an explicit deny
```

**Root Cause:**
Your AWS account has a Service Control Policy (SCP) or permissions boundary that prevents IAM User creation.

**Solution:**
Migrated from IAM User to IAM Role for ClickHouse Cloud integration:

1. **Changed Resource Type** ([main.tf:242-306](main.tf#L242-L306)):
   - Replaced `aws_iam_user` with `aws_iam_role`
   - Uses AssumeRole with External ID for security
   - ClickHouse Cloud can assume this role

2. **Added External ID Variable** ([variables.tf:31-35](variables.tf#L31-L35)):
   ```hcl
   variable "clickhouse_external_id" {
     description = "External ID for ClickHouse Cloud to assume the IAM role"
     type        = string
     default     = "clickhouse-external-id-12345"
   }
   ```

3. **Updated Outputs** ([outputs.tf:26-40](outputs.tf#L26-L40)):
   - Changed from `clickhouse_access_key_id` and `clickhouse_secret_access_key`
   - To `clickhouse_role_arn` and `clickhouse_external_id`

---

### 3. Iceberg Crawler Target Mixing Error

**Error:**
```
InvalidInputException: The crawler cannot have iceberg targets mixed with other target types.
```

**Root Cause:**
AWS Glue Crawlers cannot have both `iceberg_target` and `s3_target` in the same crawler.

**Fix:**
Removed `s3_target` from Iceberg crawler ([main.tf:163-168](main.tf#L163-L168)):
```hcl
# Removed this block:
# s3_target {
#   path = "s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/"
# }

# Kept only:
iceberg_target {
  paths = [
    "s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/"
  ]
  maximum_traversal_depth = 3
}
```

---

### 4. Iceberg Target Recrawl Policy Error

**Error:**
```
InvalidInputException: RecrawlBehavior "Crawl new folders only" can only apply to Amazon S3 target.
```

**Root Cause:**
The `recrawl_policy` configuration is only valid for S3 targets, not Iceberg targets.

**Fix:**
Removed `recrawl_policy` from Iceberg crawler ([main.tf:170-173](main.tf#L170-L173)):
```hcl
# Removed this block:
# recrawl_policy {
#   recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
# }
```

---

## Deployment Architecture Changes

### Before (Original Design)
- **Authentication**: IAM User with Access Keys
- **Glue Crawler**: Mixed S3 and Iceberg targets
- **Schema Policy**: UPDATE_IN_DATABASE

### After (Fixed Design)
- **Authentication**: IAM Role with AssumeRole + External ID
- **Glue Crawler**: Separate crawlers for S3 (CSV/Parquet) and Iceberg
- **Schema Policy**: LOG only for recrawl policies

---

## Current Working Configuration

### Deployed Resources
✅ S3 Bucket: `chc-iceberg-data-123456789012`
✅ Glue Database: `clickhouse_iceberg_db`
✅ Glue Crawlers:
  - `chc-glue-integration-csv-crawler`
  - `chc-glue-integration-parquet-crawler`
  - `chc-glue-integration-iceberg-crawler`
✅ IAM Role: `chc-glue-integration-clickhouse-role`

### Integration Details
- **Role ARN**: `arn:aws:iam::123456789012:role/chc-glue-integration-clickhouse-role`
- **Region**: `ap-northeast-2`
- **External ID**: (retrieve with `terraform output -raw clickhouse_external_id`)

---

## ClickHouse Cloud Configuration

### Step 1: Configure IAM Role in ClickHouse Cloud

1. Go to ClickHouse Cloud Console
2. Navigate to **Settings > Integrations > AWS**
3. Add IAM Role:
   - **Role ARN**: `arn:aws:iam::123456789012:role/chc-glue-integration-clickhouse-role`
   - **External ID**: (from terraform output)
   - **Region**: `ap-northeast-2`

### Step 2: Test Integration

```sql
-- Test S3 access
SELECT * FROM s3(
  's3://chc-iceberg-data-123456789012/csv/*.csv',
  'CSV'
) LIMIT 10;

-- Test Iceberg table
CREATE TABLE test_iceberg
ENGINE = IcebergS3(
  's3://chc-iceberg-data-123456789012/iceberg/sales_data/',
  'AWS'
);

SELECT * FROM test_iceberg LIMIT 10;
```

---

## Lessons Learned

1. **IAM Roles vs Users**: Always prefer IAM Roles over Users when possible
   - More secure (no long-lived credentials)
   - Better for cross-account access
   - Easier to rotate and audit

2. **Glue Crawler Target Types**:
   - Cannot mix Iceberg and S3 targets
   - Different target types have different policy requirements
   - Iceberg targets don't support recrawl policies

3. **Schema Change Policies**:
   - Recrawl behavior restrictions affect schema change policies
   - "CRAWL_NEW_FOLDERS_ONLY" requires LOG-only schema policies

4. **Permission Boundaries**:
   - Always check for SCPs and permission boundaries
   - Design for least-privilege from the start
   - Use IAM Roles when user creation is restricted

---

## Next Steps

1. ✅ Infrastructure deployed successfully
2. ⏳ Upload sample data: `./scripts/upload-sample-data.sh`
3. ⏳ Run Glue crawlers
4. ⏳ Configure ClickHouse Cloud integration
5. ⏳ Test queries

---

## Troubleshooting Tips

### Check Crawler Status
```bash
aws glue get-crawler --name chc-glue-integration-iceberg-crawler
```

### Test IAM Role Assumption
```bash
aws sts assume-role \
  --role-arn arn:aws:iam::123456789012:role/chc-glue-integration-clickhouse-role \
  --role-session-name test-session \
  --external-id $(terraform output -raw clickhouse_external_id)
```

### Verify S3 Bucket Access
```bash
aws s3 ls s3://chc-iceberg-data-123456789012/
```

---

## References

- [AWS Glue Crawler Documentation](https://docs.aws.amazon.com/glue/latest/dg/add-crawler.html)
- [ClickHouse Iceberg Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)
- [AWS IAM Roles Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
