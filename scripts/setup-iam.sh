#!/usr/bin/env bash
# Run with --help for full usage. Requires: bash >= 3.2, aws CLI v2.

set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Set up AWS IAM for GitHub Actions integration tests.
Creates an OIDC role (recommended) AND a static IAM user (fallback).
All steps are idempotent — safe to run multiple times.

Compatible with macOS, Linux, and WSL. Requires: bash >= 3.2, aws CLI v2.
WSL note: keep LF line endings — dos2unix scripts/setup-iam.sh if needed.

Usage: $(basename "$0") [options]

Options:
  --account  <id>       AWS account ID (default: resolved from current credentials)
  --region   <r>        AWS region (default: us-east-1)
  --repo     <org/name> GitHub repository in org/name format
                        (default: mpechner/tfvar_backup)
  --role-name <name>    IAM role name for OIDC (default: github-tfvar-backup-inttest)
  --user-name <name>    IAM user name for static keys (default: github-tfvar-backup-inttest-user)
  --dry-run             Show what would be created without making any AWS calls
  -h, --help            Show this help

What this creates:
  1. An OIDC identity provider for token.actions.githubusercontent.com
     (one per AWS account — skipped if it already exists)
  2. An IAM role with a trust policy scoped to the GitHub repo  [OIDC path]
  3. An S3 inline policy scoped to tfvar-inttest-* on the role  [OIDC path]
  4. An IAM user with the same S3 inline policy                 [static key path]
  5. An IAM access key for the user (printed once — save it)    [static key path]

After running, configure GitHub Actions — either option works:

  Option A (recommended): Set repository VARIABLE
    OIDC_ROLE_ARN = <printed role ARN>

  Option B (fallback): Set repository SECRETS
    AWS_ACCESS_KEY_ID     = <printed key ID>
    AWS_SECRET_ACCESS_KEY = <printed secret>

  Settings → Secrets/Variables → Actions

Examples:
  $(basename "$0")
  $(basename "$0") --account 123456789012
  $(basename "$0") --region us-west-2
  $(basename "$0") --repo org/other-repo
  $(basename "$0") --dry-run
EOF
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────────
REGION="us-east-1"
GITHUB_REPO="mpechner/tfvar_backup"
ROLE_NAME="github-tfvar-backup-inttest"
USER_NAME="github-tfvar-backup-inttest-user"
ACCOUNT_ID=""
DRY_RUN=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage ;;
    --dry-run)      DRY_RUN=true ;;
    --account)      [[ $# -gt 1 ]] || { echo "ERROR: --account requires a value";   exit 1; }
                    ACCOUNT_ID="$2";  shift ;;
    --region)       [[ $# -gt 1 ]] || { echo "ERROR: --region requires a value";    exit 1; }
                    REGION="$2";      shift ;;
    --repo)         [[ $# -gt 1 ]] || { echo "ERROR: --repo requires a value";      exit 1; }
                    GITHUB_REPO="$2"; shift ;;
    --role-name)    [[ $# -gt 1 ]] || { echo "ERROR: --role-name requires a value"; exit 1; }
                    ROLE_NAME="$2";   shift ;;
    --user-name)    [[ $# -gt 1 ]] || { echo "ERROR: --user-name requires a value"; exit 1; }
                    USER_NAME="$2";   shift ;;
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
  aws_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
  aws_major=$(echo "$aws_version" | cut -d. -f1)
  if [[ "$aws_major" -lt 2 ]]; then
    echo "ERROR: aws CLI v2 required (found v${aws_version}). Upgrade at https://aws.amazon.com/cli/"
    preflight_ok=false
  fi
fi

[[ "$preflight_ok" == "true" ]] || exit 1

# ── Resolve account ID ────────────────────────────────────────────────────────
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
USER_ARN="arn:aws:iam::${ACCOUNT_ID}:user/${USER_NAME}"

echo ""
echo "── tfvar-backup IAM setup ───────────────────────────────"
echo "  Account   : ${ACCOUNT_ID}"
echo "  Region    : ${REGION}"
echo "  Repo      : ${GITHUB_REPO}"
echo "  Role      : ${ROLE_NAME}"
echo "  User      : ${USER_NAME}"
[[ "$DRY_RUN" == "true" ]] && echo "  Mode      : DRY RUN — no AWS calls will be made"
echo ""

# ── Shared S3 policy document ─────────────────────────────────────────────────
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
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketLogging",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketPublicAccessBlock"
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

# ── Step 1: OIDC provider ─────────────────────────────────────────────────────
echo "── Step 1: OIDC provider ────────────────────────────────"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would create OIDC provider: ${OIDC_ARN}"
elif aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" &>/dev/null; then
  echo "  [skip] Already exists: ${OIDC_ARN}"
else
  echo "  [create] Registering GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  echo "  [ok] OIDC provider created."
fi

# ── Step 2: OIDC role ─────────────────────────────────────────────────────────
echo ""
echo "── Step 2: OIDC role ────────────────────────────────────"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike":  { "${OIDC_URL}:sub": "repo:${GITHUB_REPO}:*" },
      "StringEquals": { "${OIDC_URL}:aud": "sts.amazonaws.com" }
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
  echo "  [update] Refreshing trust policy..."
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

# ── Step 3: S3 policy on role ─────────────────────────────────────────────────
echo ""
echo "── Step 3: S3 policy → role ─────────────────────────────"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would attach inline policy 'tfvar-inttest-s3' to role ${ROLE_NAME}"
else
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "tfvar-inttest-s3" \
    --policy-document "$S3_POLICY"
  echo "  [ok] S3 policy attached to role."
fi

# ── Step 4: IAM user (static key fallback) ────────────────────────────────────
echo ""
echo "── Step 4: IAM user (static key fallback) ───────────────"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] Would create user: ${USER_ARN}"
  echo "  [dry-run] Would attach inline policy 'tfvar-inttest-s3' to user ${USER_NAME}"
  echo "  [dry-run] Would create access key for ${USER_NAME}"
else
  if aws iam get-user --user-name "$USER_NAME" &>/dev/null; then
    echo "  [skip] User already exists: ${USER_ARN}"
  else
    echo "  [create] Creating user ${USER_NAME}..."
    aws iam create-user \
      --user-name "$USER_NAME" \
      --tags Key=Purpose,Value=tfvar-backup-inttest
    echo "  [ok] User created."
  fi

  echo "  [update] Attaching inline S3 policy to user..."
  aws iam put-user-policy \
    --user-name "$USER_NAME" \
    --policy-name "tfvar-inttest-s3" \
    --policy-document "$S3_POLICY"
  echo "  [ok] S3 policy attached to user."

  # Check for existing keys — warn if already at the limit (2), otherwise create one
  existing_keys=$(aws iam list-access-keys --user-name "$USER_NAME" \
    --query 'AccessKeyMetadata[*].AccessKeyId' --output text)
  key_count=$(echo "$existing_keys" | grep -c '\S' || true)

  if [[ "$key_count" -ge 2 ]]; then
    echo "  [warn] User already has 2 access keys (AWS limit). Delete one to rotate:"
    echo "         aws iam delete-access-key --user-name ${USER_NAME} --access-key-id <KEY_ID>"
    ACCESS_KEY_ID="<existing — see above>"
    SECRET_ACCESS_KEY="<not shown — create a new key after deleting an old one>"
  elif [[ "$key_count" -ge 1 ]]; then
    echo "  [skip] Access key already exists for ${USER_NAME}."
    echo "  [info] To rotate: delete the existing key and re-run this script."
    ACCESS_KEY_ID="<existing — check AWS console or re-run after rotating>"
    SECRET_ACCESS_KEY="<not shown>"
  else
    echo "  [create] Creating access key..."
    key_json=$(aws iam create-access-key --user-name "$USER_NAME" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
    ACCESS_KEY_ID=$(echo "$key_json" | awk '{print $1}')
    SECRET_ACCESS_KEY=$(echo "$key_json" | awk '{print $2}')
    echo "  [ok] Access key created."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run complete — no changes made."
  echo ""
  echo "  Run without --dry-run to apply."
else
  echo "✓ Done. Configure ONE of the following in GitHub Actions:"
  echo ""
  echo "  ┌─ Option A: OIDC (recommended — no secrets to store) ──────────────────"
  echo "  │  Settings → Variables → Actions → New repository variable"
  echo "  │"
  echo "  │  OIDC_ROLE_ARN = ${ROLE_ARN}"
  echo "  └────────────────────────────────────────────────────────────────────────"
  echo ""
  echo "  ┌─ Option B: Static key (fallback) ─────────────────────────────────────"
  echo "  │  Settings → Secrets → Actions → New repository secret"
  echo "  │"
  echo "  │  AWS_ACCESS_KEY_ID     = ${ACCESS_KEY_ID}"
  echo "  │  AWS_SECRET_ACCESS_KEY = ${SECRET_ACCESS_KEY}"
  echo "  └────────────────────────────────────────────────────────────────────────"
  echo ""
  echo "  ⚠  The secret key is shown only once. Store it now."
fi
