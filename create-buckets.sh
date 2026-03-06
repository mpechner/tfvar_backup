#!/bin/bash
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Create the two S3 buckets required for tfvars backup. Idempotent — safe to run multiple times.

Usage: $(basename "$0") <tfvars-bucket> [options]

Arguments:
  <tfvars-bucket>     Versioned backup bucket name (required)

Options:
  --logging <bucket>  Access-log bucket name (default: <tfvars-bucket>-objectlogs)
  --region <r>        AWS region for both buckets (default: us-east-1)
  --account <id>      Assume terraform-execute role in this account ID
  -h, --help          Show this help

Buckets created:
  <tfvars-bucket>         Versioned, SSE-KMS (aws/s3), noncurrent versions expire after 90 days
  <tfvars-bucket>-objectlogs  Server-access log target, SSE-KMS (aws/s3)

Logging prefix format:
  <git-repo-name>/[YYYY]-[MM]-[DD]-[hh]-[mm]-[ss]-[UniqueString]

Examples:
  $(basename "$0") my-tfvars-backup
  $(basename "$0") my-tfvars-backup --region us-west-2
  $(basename "$0") my-tfvars-backup --account 123456789012 --logging my-custom-logs
EOF
  exit 0
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ $# -lt 1 ] && { echo "ERROR: <tfvars-bucket> is required."; echo ""; usage; }

# ── Parse arguments ───────────────────────────────────────────────────────────
TFVARS_BUCKET="$1"
shift

REGION="us-east-1"
ACCOUNT_ID=""
LOGGING_BUCKET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --region)  [ $# -gt 1 ] || { echo "ERROR: --region requires a value"; exit 1; }; REGION="$2";        shift ;;
    --account) [ $# -gt 1 ] || { echo "ERROR: --account requires a value"; exit 1; }; ACCOUNT_ID="$2";   shift ;;
    --logging) [ $# -gt 1 ] || { echo "ERROR: --logging requires a value"; exit 1; }; LOGGING_BUCKET="$2"; shift ;;
    *) echo "ERROR: Unknown argument: $1"; echo ""; usage ;;
  esac
  shift
done

LOGGING_BUCKET="${LOGGING_BUCKET:-${TFVARS_BUCKET}-objectlogs}"

# ── Optionally assume terraform-execute ───────────────────────────────────────
if [ -n "$ACCOUNT_ID" ]; then
  echo "Assuming terraform-execute role in account $ACCOUNT_ID..."
  TEMP_CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/terraform-execute" \
    --role-session-name "create-buckets" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
  export AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS"     | awk '{print $1}')
  export AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | awk '{print $2}')
  export AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS"     | awk '{print $3}')
fi

# Auto-detect git repo name from the remote URL, falling back to the directory name.
REPO_NAME=$(git -C "$(dirname "${BASH_SOURCE[0]}")" remote get-url origin 2>/dev/null \
  | sed 's|.*[/:]||; s|\.git$||') \
  || REPO_NAME=$(basename "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)")
if [ -z "${REPO_NAME:-}" ]; then
  echo "ERROR: Could not determine git repo name. Run from inside a git repository."
  exit 1
fi

LOGGING_PREFIX="${REPO_NAME}/"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns 0 if the bucket already exists and we own it, 1 otherwise.
bucket_exists() {
  local bucket="$1"
  aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null
}

# Create a bucket if it does not already exist.
# us-east-1 must NOT pass --create-bucket-configuration; every other region must.
create_bucket_if_missing() {
  local bucket="$1"
  local description="$2"

  if bucket_exists "$bucket"; then
    echo "  [skip] Bucket already exists: s3://${bucket}"
    return 0
  fi

  echo "  [create] Creating bucket: s3://${bucket} (${REGION})"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "  [ok] Created: s3://${bucket}"
}

# Block all public access on a bucket (idempotent — re-applying is harmless).
block_public_access() {
  local bucket="$1"
  echo "  [config] Blocking public access on s3://${bucket}..."
  aws s3api put-public-access-block \
    --bucket "$bucket" \
    --region "$REGION" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

# Enable SSE-KMS default encryption using the AWS-managed aws/s3 key (idempotent).
enable_default_encryption() {
  local bucket="$1"
  echo "  [config] Enabling SSE-KMS (aws/s3) default encryption on s3://${bucket}..."
  aws s3api put-bucket-encryption \
    --bucket "$bucket" \
    --region "$REGION" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "alias/aws/s3"
        },
        "BucketKeyEnabled": true
      }]
    }'
}

# Expire noncurrent object versions after 90 days (idempotent).
apply_version_lifecycle() {
  local bucket="$1"
  echo "  [config] Applying lifecycle rule: expire noncurrent versions after 90 days on s3://${bucket}..."
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --region "$REGION" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "expire-noncurrent-versions-90d",
        "Status": "Enabled",
        "Filter": { "Prefix": "" },
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 90
        }
      }]
    }'
}

# ── Step 1: Logging bucket ────────────────────────────────────────────────────
echo ""
echo "── Logging bucket: s3://${LOGGING_BUCKET} ──────────────────────────────"

create_bucket_if_missing "$LOGGING_BUCKET" "access-log target"
block_public_access       "$LOGGING_BUCKET"
enable_default_encryption "$LOGGING_BUCKET"

echo "  [ok] Logging bucket ready."

# ── Step 2: Versioned tfvars backup bucket ────────────────────────────────────
echo ""
echo "── Backup bucket: s3://${TFVARS_BUCKET} ────────────────────────────────"

create_bucket_if_missing "$TFVARS_BUCKET" "versioned tfvars backup"
block_public_access       "$TFVARS_BUCKET"
enable_default_encryption "$TFVARS_BUCKET"

# Enable versioning (idempotent — enabling an already-enabled bucket is a no-op).
echo "  [config] Enabling versioning on s3://${TFVARS_BUCKET}..."
aws s3api put-bucket-versioning \
  --bucket "$TFVARS_BUCKET" \
  --region "$REGION" \
  --versioning-configuration Status=Enabled

apply_version_lifecycle "$TFVARS_BUCKET"

# Enable server access logging → logging bucket with prefix pattern:
#   <GIT_REPO_NAME>/[YYYY]-[MM]-[DD]-[hh]-[mm]-[ss]-[UniqueString]
echo "  [config] Enabling server access logging → s3://${LOGGING_BUCKET}/${LOGGING_PREFIX}..."
aws s3api put-bucket-logging \
  --bucket "$TFVARS_BUCKET" \
  --region "$REGION" \
  --bucket-logging-status "{
    \"LoggingEnabled\": {
      \"TargetBucket\": \"${LOGGING_BUCKET}\",
      \"TargetPrefix\": \"${LOGGING_PREFIX}\"
    }
  }"

echo "  [ok] Backup bucket ready."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "✓ All done."
echo ""
echo "  Backup bucket : s3://${TFVARS_BUCKET}"
echo "    versioning  : enabled"
echo "    encryption  : SSE-KMS (aws/s3)"
echo "    lifecycle   : noncurrent versions expire after 90 days"
echo "    logging  →  : s3://${LOGGING_BUCKET}/${LOGGING_PREFIX}"
echo ""
echo "  Logging bucket: s3://${LOGGING_BUCKET}"
echo "    encryption  : SSE-KMS (aws/s3)"
echo "    public access: blocked"
