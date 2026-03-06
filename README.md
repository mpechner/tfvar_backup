# tfvar_backup

Terraform `tfvars` files hold environment-specific configuration — hostnames, CIDRs, instance sizes, feature flags. They are not secrets per se, but they are also not committed to the repo. Losing them means manually reconstructing the state of every environment from scratch.

This toolset provides a simple, repeatable way to back them up to S3 and restore them when needed.

---

## Why

`terraform.tfvars` files are deliberately gitignored in most shops. They often contain values that are environment-specific and change frequently, or values that are sensitive enough that they shouldn't live in version history even in a private repo. The tradeoff is that they exist only on whoever's laptop last ran Terraform — which is a fragile place for configuration that describes production infrastructure.

Backing them up to a versioned S3 bucket gives you:

- A durable, auditable history of what configuration was applied and when
- The ability to restore a single file or an entire repo's worth of config in one command
- Object-level access logging so you can see who retrieved what and when

---

## Scripts

### `create-buckets.sh`

Creates the two S3 buckets needed before the first backup. Safe to run multiple times — all operations are idempotent.

**Backup bucket** (`<tfvars-bucket>`):
- Versioning enabled — every push creates a new version, nothing is ever overwritten
- SSE-KMS encryption using the AWS-managed `aws/s3` key — no key management overhead
- Lifecycle rule — noncurrent versions older than 90 days are permanently deleted
- Server access logging enabled

**Logging bucket** (`<tfvars-bucket>-objectlogs`):
- Receives S3 server access logs for the backup bucket
- Log prefix is the git repo name, so logs from multiple repos can share one logging bucket without colliding
- SSE-KMS encrypted, public access blocked

```
./create-buckets.sh my-tfvars-backup
./create-buckets.sh my-tfvars-backup --region us-west-2
./create-buckets.sh my-tfvars-backup --account 123456789012
```

---

### `backup-tfvars.sh`

Pushes all `terraform.tfvars` files found under a repo directory to S3, or restores them back.

**S3 key structure:**
```
s3://<bucket>/<git-repo-name>/<relative-path-from-repo-root>/terraform.tfvars
```

The repo name is taken from `git remote get-url origin` — not the directory name — so it stays stable regardless of where the repo is checked out. If no remote is configured it falls back to the directory basename.

**Push** (default):
```bash
./backup-tfvars.sh my-bucket                          # current directory
./backup-tfvars.sh my-bucket ../tf_take2              # relative path
./backup-tfvars.sh my-bucket /home/me/dev/tf_take2    # absolute path
./backup-tfvars.sh my-bucket --dry-run ../tf_take2    # preview without uploading
```

**Pull** (must be run from inside the repo):
```bash
cd ~/dev/tf_take2
./backup-tfvars.sh my-bucket --pull                   # restore everything
./backup-tfvars.sh my-bucket --pull --diff            # show diff before applying
./backup-tfvars.sh my-bucket --pull-file deployments/dev-cluster/terraform.tfvars
./backup-tfvars.sh my-bucket --pull-file deployments/dev-cluster/terraform.tfvars --diff
```

Pull requires you to be inside the target repo rather than passing a path to it. This is intentional — it prevents accidentally overwriting files in the wrong directory.

**List:**
```bash
./backup-tfvars.sh my-bucket --list
```

---

## Cross-account access

Both scripts support assuming a `terraform-execute` IAM role in another account via `--account`. This is useful when the S3 bucket lives in a shared services account but the scripts are run from a developer account.

```bash
./create-buckets.sh my-bucket --account 364082771643
./backup-tfvars.sh my-bucket --account 364082771643 --pull
```

---

## Requirements

- AWS CLI configured with credentials that have S3 and STS access
- `git` (for repo name detection)
- `diff` (for `--diff` mode)
