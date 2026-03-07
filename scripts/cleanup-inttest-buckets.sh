#!/usr/bin/env bash
# Finds and deletes all tfvar-inttest-* buckets left behind by failed CI runs.
# Run with --help for full usage. Requires: bash >= 3.2, aws CLI v2.

set -euo pipefail

usage() {
  cat <<EOF
Find and delete all tfvar-inttest-* buckets left behind by failed CI runs.

Usage: $(basename "$0") [options]

Options:
  --region   <r>   AWS region to search (default: us-east-1)
  --prefix   <p>   Bucket name prefix to match (default: tfvar-inttest-)
  --dry-run        List buckets that would be deleted without deleting anything
  -h, --help       Show this help

Examples:
  $(basename "$0") --dry-run
  $(basename "$0")
  $(basename "$0") --region us-west-2
EOF
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────────
REGION="us-east-1"
PREFIX="tfvar-inttest-"
DRY_RUN=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage ;;
    --dry-run)   DRY_RUN=true ;;
    --region)    [[ $# -gt 1 ]] || { echo "ERROR: --region requires a value"; exit 1; }
                 REGION="$2"; shift ;;
    --prefix)    [[ $# -gt 1 ]] || { echo "ERROR: --prefix requires a value"; exit 1; }
                 PREFIX="$2"; shift ;;
    *) echo "ERROR: Unknown argument: $1"; echo ""; usage ;;
  esac
  shift
done

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. Install from https://aws.amazon.com/cli/"
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install from https://stedolan.github.io/jq/"
  exit 1
fi

# ── Find matching buckets ─────────────────────────────────────────────────────
echo ""
echo "── Scanning for buckets matching '${PREFIX}*' in ${REGION} ──────────────"

buckets=()
while IFS= read -r line; do
  [[ -n "$line" ]] && buckets+=("$line")
done < <(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '${PREFIX}')].Name" \
  --output text | tr '\t' '\n' | grep -v '^$' | sort)

if [[ ${#buckets[@]} -eq 0 ]]; then
  echo "  No matching buckets found."
  exit 0
fi

echo "  Found ${#buckets[@]} bucket(s):"
for b in "${buckets[@]}"; do
  echo "    s3://${b}"
done
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run — no buckets deleted."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
read -r -p "Delete all ${#buckets[@]} bucket(s)? [y/N] " confirm
if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Delete each bucket ────────────────────────────────────────────────────────
errors=0

for bucket in "${buckets[@]}"; do
  echo ""
  echo "── s3://${bucket} ──────────────────────────────────────────────"

  # Purge all object versions and delete markers
  versions=$(aws s3api list-object-versions \
    --bucket "$bucket" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null)
  markers=$(aws s3api list-object-versions \
    --bucket "$bucket" \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null)

  objects=$(jq -n \
    --argjson v "${versions:-null}" \
    --argjson m "${markers:-null}" \
    '[($v // [])[], ($m // [])[]] | map(select(. != null))')

  if [[ "$objects" != "[]" && -n "$objects" ]]; then
    echo "  Deleting object versions..."
    echo "$objects" \
      | jq '{Objects: ., Quiet: true}' \
      | aws s3api delete-objects \
          --bucket "$bucket" \
          --delete file:///dev/stdin \
          --output json > /dev/null
    echo "  Object versions deleted."
  else
    echo "  No object versions to delete."
  fi

  # Delete the bucket
  if aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
    echo "  ✓ Deleted."
  else
    echo "  ERROR: Failed to delete s3://${bucket}"
    errors=$((errors + 1))
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $errors -eq 0 ]]; then
  echo "✓ Done. All ${#buckets[@]} bucket(s) deleted."
else
  echo "⚠ Done with ${errors} error(s). Check output above."
  exit 1
fi
