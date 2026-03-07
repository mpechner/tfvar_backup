#!/bin/bash
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Backup all terraform.tfvars files to S3.

Usage: $(basename "$0") <bucket> [options] [<repo-dir>]

Arguments:
  <bucket>              S3 bucket name (required)
  <repo-dir>            Path to the repo: omit or . for current dir, ../tf_foobar,
                        or /abs/path/to/repo  (default: .)
                        The git remote name is used as the S3 key prefix.
                        For --pull / --pull-file, must resolve to the current directory.

Options:
  --push                Push tfvars to S3 (default)
  --pull                Restore all tfvars from S3 (must be run from the repo root)
  --pull-file <path>    Restore a single tfvars file from S3 (repo-relative path,
                        e.g. deployments/dev-cluster/terraform.tfvars)
  --list                List tfvars stored in S3
  --dry-run             Show what would be pushed without uploading
  --diff                On --pull / --pull-file, show a diff of each file before applying
  --region <r>          AWS region (default: us-east-1)
  --account <id>        Assume terraform-execute role in this account ID
  -h, --help            Show this help

S3 path format:
  s3://<bucket>/<git-repo-name>/<relative-path>/terraform.tfvars

Examples:
  $(basename "$0") my-bucket
  $(basename "$0") my-bucket ../dev/foobar
  $(basename "$0") --dry-run my-bucket ../tf_take2
  $(basename "$0") my-bucket --region us-west-2 --dry-run ../tf_foobar
  $(basename "$0") --account 123456789012 my-bucket --pull
  $(basename "$0") my-bucket --pull-file deployments/dev/terraform.tfvars
  $(basename "$0") my-bucket --pull --diff
  $(basename "$0") my-bucket --pull-file deployments/dev/terraform.tfvars --diff
EOF
  exit 0
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ $# -lt 1 ] && { echo "ERROR: <bucket> is required."; echo ""; usage; }

TFVARS_BUCKET=""
MODE=""
REGION="us-east-1"
ACCOUNT_ID=""
REPO_DIR_ARG="."
PULL_FILE=""
DIFF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --push|--pull|--list|--dry-run) MODE="$1" ;;
    --pull-file)
      [ $# -gt 1 ] || { echo "ERROR: --pull-file requires a value"; exit 1; }
      PULL_FILE="$2"; MODE="--pull-file"; shift ;;
    --region)
      [ $# -gt 1 ] || { echo "ERROR: --region requires a value"; exit 1; }
      REGION="$2"; shift ;;
    --account)
      [ $# -gt 1 ] || { echo "ERROR: --account requires a value"; exit 1; }
      ACCOUNT_ID="$2"; shift ;;
    --diff) DIFF=1 ;;
    -*) echo "ERROR: Unknown flag: $1"; exit 1 ;;
    *)
      if [ -z "$TFVARS_BUCKET" ]; then
        TFVARS_BUCKET="$1"
      else
        REPO_DIR_ARG="$1"
      fi ;;
  esac
  shift
done

if [ -z "$TFVARS_BUCKET" ]; then
  echo "ERROR: <bucket> is required."; echo ""; usage
fi

# ── Resolve repo root ────────────────────────────────────────────────────────
# For push/list/dry-run: resolve the supplied path (default .).
# For pull: must be run from the repo root — reject any path that isn't cwd.
if [ "$MODE" = "--pull" ] || [ "$MODE" = "--pull-file" ]; then
  REPO_ROOT="$(pwd)"
  if [ "$REPO_DIR_ARG" != "." ] && [ "$(cd "$REPO_DIR_ARG" && pwd)" != "$REPO_ROOT" ]; then
    echo "ERROR: --pull and --pull-file restore into the current directory."
    echo "  cd into the repo first, or omit the <repo-dir> argument."
    exit 1
  fi
else
  REPO_ROOT="$(cd "$REPO_DIR_ARG" && pwd)"
fi

# Derive repo name from git remote URL (strips host/org, drops .git suffix).
# Falls back to the directory basename if not a git repo or no remote is set.
REPO_NAME=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
  | sed 's|.*[/:]||; s|\.git$||') || true
if [ -z "${REPO_NAME:-}" ]; then
  REPO_NAME="$(basename "$REPO_ROOT")"
fi

# ── Optionally assume terraform-execute ───────────────────────────────────────
if [ -n "$ACCOUNT_ID" ]; then
  echo "Assuming terraform-execute role in account $ACCOUNT_ID..."
  TEMP_CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/terraform-execute" \
    --role-session-name "backup-tfvars" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS"     | awk '{print $1}')
  AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | awk '{print $2}')
  AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS"     | awk '{print $3}')
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
s3_key_for() {
  local file="$1"
  local rel="${file#$REPO_ROOT/}"
  echo "${REPO_NAME}/${rel}"
}

# Download one S3 key to its local path, optionally showing a diff first.
apply_one() {
  local key="$1"
  local rel="${key#${REPO_NAME}/}"
  local local_path="${REPO_ROOT}/${rel}"
  local local_dir
  local_dir="$(dirname "$local_path")"

  mkdir -p "$local_dir"

  if [ "$DIFF" = "1" ]; then
    local tmp
    tmp="$(mktemp)"
    aws s3 cp "s3://${TFVARS_BUCKET}/${key}" "$tmp" --region "$REGION" >/dev/null
    echo "  ── diff: ${local_path} ──────────────────────────────"
    if [ -f "$local_path" ]; then
      diff -u "$local_path" "$tmp" || true
    else
      echo "  (new file — no local copy exists)"
      cat "$tmp"
    fi
    echo ""
    rm -f "$tmp"
  fi

  echo "  ← s3://${TFVARS_BUCKET}/${key}"
  echo "       → ${local_path}"
  aws s3 cp "s3://${TFVARS_BUCKET}/${key}" "$local_path" --region "$REGION"
}

# ── List mode ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "--list" ]; then
  echo "Listing tfvars in s3://${TFVARS_BUCKET}/${REPO_NAME}/"
  aws s3 ls "s3://${TFVARS_BUCKET}/${REPO_NAME}/" --recursive --region "$REGION"
  exit 0
fi

# ── Pull-file mode ────────────────────────────────────────────────────────────
if [ "$MODE" = "--pull-file" ]; then
  # Normalise: strip leading ./ or / and ensure it ends with terraform.tfvars
  PULL_FILE="${PULL_FILE#./}"
  PULL_FILE="${PULL_FILE#/}"
  KEY="${REPO_NAME}/${PULL_FILE}"

  echo "Restoring s3://${TFVARS_BUCKET}/${KEY} → ${REPO_ROOT}/${PULL_FILE}"
  echo ""
  apply_one "$KEY"
  echo ""
  echo "✓ Restored 1 terraform.tfvars file"
  exit 0
fi

# ── Pull mode ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "--pull" ]; then
  echo "Restoring tfvars from s3://${TFVARS_BUCKET}/${REPO_NAME}/ → $REPO_ROOT"
  echo ""

  OBJECTS=$(aws s3 ls "s3://${TFVARS_BUCKET}/${REPO_NAME}/" \
    --recursive --region "$REGION" \
    | awk '{print $4}' | grep 'terraform\.tfvars$')

  if [ -z "$OBJECTS" ]; then
    echo "No terraform.tfvars files found in s3://${TFVARS_BUCKET}/${REPO_NAME}/"
    exit 0
  fi

  COUNT=0
  while IFS= read -r key; do
    apply_one "$key"
    COUNT=$((COUNT + 1))
  done <<< "$OBJECTS"

  echo ""
  echo "✓ Restored $COUNT terraform.tfvars file(s)"
  exit 0
fi

# ── Push mode (default) ───────────────────────────────────────────────────────
DRY_RUN=0
[ "$MODE" = "--dry-run" ] && DRY_RUN=1

# Find all terraform.tfvars files, excluding .terraform and .git
TFVARS=$(find "$REPO_ROOT" -type f -name "terraform.tfvars" \
  -not -path "*/.terraform/*" \
  -not -path "*/.git/*" \
  | sort)

if [ -z "$TFVARS" ]; then
  echo "No terraform.tfvars files found under $REPO_ROOT"
  exit 0
fi

echo "Backing up terraform.tfvars files to s3://${TFVARS_BUCKET}/"
[ "$DRY_RUN" = "1" ] && echo "(dry-run — no files will be uploaded)"
echo ""

COUNT=0
while IFS= read -r file; do
  key=$(s3_key_for "$file")
  echo "  → s3://${TFVARS_BUCKET}/${key}"
  if [ "$DRY_RUN" = "0" ]; then
    aws s3 cp "$file" "s3://${TFVARS_BUCKET}/${key}" \
      --region "$REGION" \
      --sse aws:kms
  fi
  COUNT=$((COUNT + 1))
done <<< "$TFVARS"

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "✓ Dry run complete — $COUNT file(s) would be uploaded"
else
  echo "✓ Backed up $COUNT terraform.tfvars file(s) to s3://${TFVARS_BUCKET}/"
fi
