#!/usr/bin/env bash
# Run with --help for full usage. Requires: bash >= 3.2, aws CLI v2.

set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Set up the AWS IAM OIDC provider and role that allows GitHub Actions to run
the tfvar-backup integration tests without storing any long-lived AWS keys.

Compatible with macOS, Linux, and WSL. Requires: bash >= 3.2, aws CLI v2.
WSL note: keep LF line endings — dos2unix scripts/setup-iam.sh if needed.

Usage: $(basename "$0") [options]

Options:
  --account <id>       AWS account ID (default: resolved from current credentials)
  --region  <r>        AWS region (default: us-east-1)
  --repo    <org/name> GitHub repository in org/name format
                       (default: mpechner/tfvar_backup)
  --role-name <name>   IAM role name to create or update
                       (default: github-tfvar-backup-inttest)
  --dry-run            Show what would be created without making any AWS calls
  -h, --help           Show this help

What this creates:
  1. An OIDC identity provider for token.actions.githubusercontent.com
     (one per AWS account — skipped if it already exists)
  2. An IAM role with a trust policy scoped to the GitHub repo
  3. An inline S3 policy scoped to tfvar-inttest-* buckets only

After running, add the printed role ARN as a GitHub Actions variable:
  Settings → Variables → Actions → New repository variable → OIDC_ROLE_ARN

Examples:
  $(basename "$0")
  $(basename "$0") --account 123456789012
  $(basename "$0") --region us-west-2
  $(basename "$0") --repo org/other-repo
  $(basename "$0") --dry-run
EOF
  exit 0
}

# ── Defaults ─────────────────────────────────────────────────────────────────
REGION="us-east-1"
GITHUB_REPO="mpechner/tfvar_backup"
ROLE_NAME="github-tfvar-backup-inttest"
ACCOUNT_ID=""
DRY_RUN=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     usage ;;
    --dry-run)     DRY_RUN=true ;;
    --account)     [[ $# -gt 1 ]] || { echo "ERROR: --account requires a value"; exit 1; }
                   ACCOUNT_ID="$2";   shift ;;
    --region)      [[ $# -gt 1 ]] || { echo "ERROR: --region requires a value"; exit 1; }
                   REGION="$2";       shift ;;
    --repo)        [[ $# -gt 1 ]] || { echo "ERROR: --repo requires a value"; exit 1; }
                   GITHUB_REPO="$2";  shift ;;
    --role-name)   [[ $# -gt 1 ]] || { echo "ERROR: --role-name requires a value"; exit 1; }
                   ROLE_NAME="$2";    shift ;;
    *) echo "ERROR: Unknown argument: $1"; echo ""; usage ;;
  esac
  shift
done

# ── Preflight checks ──────────────────────────────────────────────────────────
preflight_ok=true

if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. Install it from https://aws.amazon.com/cli/"
  preflight_ok=false
else
  # Require v2 — v1 has different JSON output in some commands
  aws_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
  aws_major=$(echo "$aws_version" | cut -d. -f1)
  if [[ "$aws_major" -lt 2 ]]; then
    echo "ERROR: aws CLI v2 required (found v${aws_version}). Upgrade at https://aws.amazon.com/cli/"
    preflight_ok=false
  fi
fi

if [[ "$preflight_ok" != "true" ]]; then
  exit 1
fi

# ── Resolve account ID if not supplied
if [[ -z "$ACCOUNT_ID" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    ACCOUNT_ID="<YOUR-ACCOUNT-ID>"
  else
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  fi
fi

OIDC_URL="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "── tfvar-backup IAM setup ───────────────────────────────"
echo "  Account : ${ACCOUNT_ID}"
echo "  Region  : ${REGION}"
echo "  Repo    : ${GITHUB_REPO}"
echo "  Role    : ${ROLE_NAME}"
[[ "$DRY_RUN" == "true" ]] && echo "  Mode    : DRY RUN — no AWS calls will be made"
echo ""

# ── Step 1: OIDC provider ─────────────────────────────────────────────────────
echo "── Step 1: OIDC provider ────────────────────────────────"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would create OIDC provider: ${OIDC_ARN}"
elif aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
    &>/dev/null; then
  echo "  [skip] OIDC provider already exists: ${OIDC_ARN}"
else
  echo "  [create] Registering GitHub OIDC provider..."
  # Thumbprint for token.actions.githubusercontent.com (stable, per GitHub docs)
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  echo "  [ok] OIDC provider created."
fi

# ── Step 2: IAM role ──────────────────────────────────────────────────────────
echo ""
echo "── Step 2: IAM role ─────────────────────────────────────"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "${OIDC_URL}:sub": "repo:${GITHUB_REPO}:*"
      },
      "StringEquals": {
        "${OIDC_URL}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would create or update role: ${ROLE_ARN}"
  echo "  [dry-run] Trust policy would allow: repo:${GITHUB_REPO}:*"
elif aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "  [skip] Role already exists: ${ROLE_ARN}"
  echo "  [update] Updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
  echo "  [ok] Trust policy updated."
else
  echo "  [create] Creating role ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Allows GitHub Actions (${GITHUB_REPO}) to run tfvar-backup integration tests"
  echo "  [ok] Role created."
fi

# ── Step 3: Inline S3 policy ──────────────────────────────────────────────────
echo ""
echo "── Step 3: S3 policy ────────────────────────────────────"

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketManagement",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:HeadBucket",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketLogging",
        "s3:PutBucketLifecycleConfiguration",
        "s3:PutPublicAccessBlock"
      ],
      "Resource": "arn:aws:s3:::tfvar-inttest-*"
    },
    {
      "Sid": "ObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:ListBucket",
        "s3:ListBucketVersions"
      ],
      "Resource": [
        "arn:aws:s3:::tfvar-inttest-*",
        "arn:aws:s3:::tfvar-inttest-*/*"
      ]
    }
  ]
}
EOF
)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would attach inline policy 'tfvar-inttest-s3' to role ${ROLE_NAME}"
else
  echo "  [update] Attaching inline S3 policy to ${ROLE_NAME}..."
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "tfvar-inttest-s3" \
    --policy-document "$S3_POLICY"
  echo "  [ok] S3 policy attached."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run complete — no changes made."
  echo ""
  echo "  Run without --dry-run to apply."
else
  echo "✓ Done."
  echo ""
  echo "  Add this as a GitHub Actions repository variable:"
  echo ""
  echo "    Name : OIDC_ROLE_ARN"
  echo "    Value: ${ROLE_ARN}"
  echo ""
  echo "  Settings → Variables → Actions → New repository variable"
fi
