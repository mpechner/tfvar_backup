# tfvar_backup

[![Latest Release](https://img.shields.io/github/v/release/mpechner/tfvar_backup)](https://github.com/mpechner/tfvar_backup/releases/latest)

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

## Tools

There are two implementations that do exactly the same thing:

| Tool | Language | When to use |
|---|---|---|
| `*.sh` | Bash + AWS CLI | Quick use, no build step required |
| Go binaries | Go + AWS SDK v2 | Scripted pipelines, cross-platform, no AWS CLI dependency |

Both implementations share identical behaviour, flags, and S3 path structure.

---

## Installing the Go binaries

### Option A — Download a pre-built release binary

Pre-built binaries for all platforms are attached to every [GitHub Release](https://github.com/mpechner/tfvar_backup/releases).

```bash
# Example: macOS arm64 (M-series)
curl -L https://github.com/mpechner/tfvar_backup/releases/latest/download/tfvar-backup-darwin-arm64 \
  -o tfvar-backup
curl -L https://github.com/mpechner/tfvar_backup/releases/latest/download/tfvar-create-buckets-darwin-arm64 \
  -o tfvar-create-buckets
chmod +x tfvar-backup tfvar-create-buckets
```

Each release also includes a `SHA256SUMS.txt` so you can verify the download:

```bash
curl -L https://github.com/mpechner/tfvar_backup/releases/latest/download/SHA256SUMS.txt -o SHA256SUMS.txt
sha256sum --check --ignore-missing SHA256SUMS.txt
```

**macOS note:** macOS Gatekeeper will block binaries downloaded from the internet the first time you run them. You have two options:

- Right-click the binary → Open → click Open in the dialog (one-time, per binary version)
- Or from the terminal:
  ```bash
  xattr -d com.apple.quarantine ./tfvar-backup ./tfvar-create-buckets
  ```

This is a one-time step per version. If you prefer to avoid it entirely, build from source (Option B).

### Option B — Build from source

Building locally avoids the Gatekeeper prompt entirely and is straightforward if you have Go installed.

**Requirements:**
- Go 1.21+ — the bootstrap script can install it if needed
- `git`
- AWS credentials configured (`~/.aws/credentials`, env vars, or instance profile)

```bash
git clone https://github.com/mpechner/tfvar_backup
cd tfvar_backup

# Build + install to ~/.local/bin in one step
./scripts/bootstrap.sh --install

# Or just build to ./bin/
./scripts/bootstrap.sh
```

**Manual build:**
```bash
make build      # → ./bin/tfvar-backup  ./bin/tfvar-create-buckets
make install    # copy to ~/.local/bin
make help       # list all targets
```

### Verify the version

```bash
tfvar-backup --version
# tfvar-backup version v1.2.3 (commit abc1234, built 2026-03-06)

tfvar-create-buckets --version
```

---

## `tfvar-create-buckets` / `create-buckets.sh`

Creates the two S3 buckets needed before the first backup. Safe to run multiple times — all operations are idempotent.

**Backup bucket** (`<tfvars-bucket>`):
- Versioning enabled — every push creates a new version, nothing is ever overwritten
- SSE-KMS encryption using the AWS-managed `aws/s3` key — no key management overhead
- Lifecycle rule — noncurrent versions older than 90 days are permanently deleted
- Server access logging enabled

**Logging bucket** (`<tfvars-bucket>-objectlogs`):
- Receives S3 server access logs for the backup bucket
- Log prefix is the git repo name so logs from multiple repos can share one logging bucket without colliding
- SSE-KMS encrypted, public access blocked

```bash
# Go binary
tfvar-create-buckets my-tfvars-backup
tfvar-create-buckets my-tfvars-backup --region us-west-2
tfvar-create-buckets my-tfvars-backup --account 123456789012

# Bash (same flags)
./create-buckets.sh my-tfvars-backup
./create-buckets.sh my-tfvars-backup --region us-west-2
./create-buckets.sh my-tfvars-backup --account 123456789012
```

---

## `tfvar-backup` / `backup-tfvars.sh`

Pushes all `terraform.tfvars` files found under a repo directory to S3, or restores them.

**S3 key structure:**
```
s3://<bucket>/<git-repo-name>/<relative-path-from-repo-root>/terraform.tfvars
```

The repo name is taken from `git remote get-url origin` — not the directory name — so it stays stable regardless of where the repo is checked out locally.

### Push (default)

```bash
# Go binary
tfvar-backup push my-bucket                       # current directory
tfvar-backup push my-bucket ../tf_take2           # relative path
tfvar-backup push my-bucket /abs/path/tf_take2    # absolute path
tfvar-backup push my-bucket ../tf_take2 --dry-run # preview without uploading

# Bash
./backup-tfvars.sh my-bucket
./backup-tfvars.sh my-bucket ../tf_take2
./backup-tfvars.sh --dry-run my-bucket ../tf_take2
```

### Pull (must be run from inside the repo)

Pull requires you to be inside the target repo rather than passing a path to it. This is intentional — it prevents accidentally overwriting files in the wrong directory.

```bash
cd ~/dev/tf_take2

# Go binary
tfvar-backup pull my-bucket                         # restore everything
tfvar-backup pull my-bucket --diff                  # show diff before applying
tfvar-backup pull-file my-bucket deployments/dev-cluster/terraform.tfvars
tfvar-backup pull-file my-bucket deployments/dev-cluster/terraform.tfvars --diff

# Bash
./backup-tfvars.sh my-bucket --pull
./backup-tfvars.sh my-bucket --pull --diff
./backup-tfvars.sh my-bucket --pull-file deployments/dev-cluster/terraform.tfvars
```

### List

```bash
tfvar-backup list my-bucket          # Go
./backup-tfvars.sh my-bucket --list  # Bash
```

---

## Cross-account access

Both tools support assuming a `terraform-execute` IAM role in another account via `--account`. This is useful when the S3 bucket lives in a shared services account but the tools are run from a developer account.

```bash
tfvar-create-buckets my-bucket --account 364082771643
tfvar-backup push my-bucket --account 364082771643
tfvar-backup pull my-bucket --account 364082771643
```

---

## Releases

Releases are created by pushing a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will automatically:
1. Run the full integration test against real AWS — **the release is blocked if any test fails**
2. Cross-compile binaries for all 5 platforms (`linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`, `windows/amd64`)
3. Generate a `SHA256SUMS.txt` checksum file
4. Publish a GitHub Release with all binaries and checksums attached
5. Auto-generate release notes from commit history

---

## GitHub Actions — required configuration

The integration test (`integration-test.yml`) creates real S3 buckets, runs push/pull round-trips, then deletes everything. It needs AWS credentials and must be explicitly enabled.

### Step 1 — Enable integration tests

In your repo: **Settings → Variables → Actions → New repository variable**

| Variable | Value |
|---|---|
| `INTEGRATION_TESTS_ENABLED` | `true` |
| `AWS_REGION` | `us-east-1` (or your preferred region) |

Without `INTEGRATION_TESTS_ENABLED=true` the integration job is skipped — compile and vet still run on every push.

### Step 2 — AWS credentials

**Option A: OIDC (recommended — no long-lived keys stored as secrets)**

OIDC lets GitHub Actions assume an IAM role directly using a short-lived token. Nothing to rotate or leak.

Run `scripts/setup-iam.sh` (uses your current AWS CLI credentials):

```bash
./scripts/setup-iam.sh                          # defaults — repo mpechner/tfvar_backup
./scripts/setup-iam.sh --account 123456789012   # explicit account ID
./scripts/setup-iam.sh --region us-west-2       # non-default region
./scripts/setup-iam.sh --repo org/other-repo    # if you forked the repo
```

The script prints the role ARN at the end. Add it as a GitHub Actions repository variable:
**Settings → Variables → Actions → New repository variable**

| Variable | Value |
|---|---|
| `OIDC_ROLE_ARN` | `arn:aws:iam::<ACCOUNT>:role/github-tfvar-backup-inttest` |

**Option B: Static IAM key**

Create an IAM user, attach the minimal policy in Step 3, generate an access key, then add:

**Settings → Secrets → Actions → New repository secret**

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key ID |
| `AWS_SECRET_ACCESS_KEY` | IAM secret access key |

Leave `OIDC_ROLE_ARN` unset — the workflow falls back to static keys automatically.

### Step 3 — Minimal IAM policy

Every S3 action used by the test is listed here — nothing more. Resources are scoped to `tfvar-inttest-*` so these credentials cannot touch any other bucket.

```json
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
```

**What each permission is used for:**

| Permission | Used by |
|---|---|
| `s3:CreateBucket` | `tfvar-create-buckets` — creates backup + logging buckets |
| `s3:DeleteBucket` | Cleanup — removes both buckets after tests |
| `s3:HeadBucket` | Idempotency check before create; existence check after delete |
| `s3:PutBucketVersioning` | `tfvar-create-buckets` — enables versioning on backup bucket |
| `s3:PutEncryptionConfiguration` | `tfvar-create-buckets` — SSE-KMS on both buckets |
| `s3:PutBucketLogging` | `tfvar-create-buckets` — access logs → logging bucket |
| `s3:PutLifecycleConfiguration` | `tfvar-create-buckets` — 90-day noncurrent version expiry |
| `s3:PutBucketPublicAccessBlock` | `tfvar-create-buckets` — blocks public access on both buckets |
| `s3:PutObject` | `tfvar-backup push` — uploads tfvars files |
| `s3:GetObject` | `tfvar-backup pull` / `pull-file` — downloads tfvars files |
| `s3:DeleteObject` / `s3:DeleteObjectVersion` | Cleanup — purges versioned objects before bucket delete |
| `s3:ListBucket` | `tfvar-backup list` — lists objects; also used by cleanup |
| `s3:ListBucketVersions` | Cleanup — lists all versions before bucket removal |

---

## Project structure

```
tfvar_backup/
├── .github/workflows/
│   ├── ci.yml                # build + vet on every push/PR
│   ├── integration-test.yml  # real S3 push/pull round-trip (requires AWS creds)
│   └── release.yml           # integration test → cross-compile → publish on tag
├── cmd/
│   ├── backup/               # tfvar-backup binary
│   └── create-buckets/       # tfvar-create-buckets binary
├── internal/
│   ├── awsutil/              # AWS config + role assumption
│   ├── gitutil/              # git remote → repo name
│   └── version/              # build-time version info (injected via ldflags)
├── scripts/
│   ├── bootstrap.sh          # install Go + build binaries
│   └── setup-iam.sh          # create OIDC provider + IAM role for CI
├── Makefile
├── backup-tfvars.sh          # Bash equivalent of tfvar-backup
├── create-buckets.sh         # Bash equivalent of tfvar-create-buckets
└── go.mod
```

---

## Requirements (Bash scripts)

- AWS CLI configured with S3 and STS access
- `git`
- `diff` (for `--diff` mode)
