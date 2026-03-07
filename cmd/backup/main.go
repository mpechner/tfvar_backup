package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/mpechner/tfvar_backup/internal/awsutil"
	"github.com/mpechner/tfvar_backup/internal/gitutil"
	"github.com/mpechner/tfvar_backup/internal/version"
	"github.com/spf13/cobra"
)

func main() {
	var (
		region    string
		accountID string
		showDiff  bool
	)

	root := &cobra.Command{
		Use:     "tfvar-backup <bucket> [repo-dir]",
		Short:   "Backup and restore terraform.tfvars files to/from S3",
		Version: version.String(),
		Long: `Backup all terraform.tfvars files to S3, or restore them.

The git remote name is used as the S3 key prefix so backups from multiple
repos can safely share one bucket.

S3 path format:
  s3://<bucket>/<git-repo-name>/<relative-path>/terraform.tfvars`,
		Example: `  tfvar-backup my-bucket
  tfvar-backup my-bucket ../tf_take2
  tfvar-backup my-bucket --region us-west-2 ../tf_take2`,
		// Shared persistent flags — available to all subcommands.
	}

	root.PersistentFlags().StringVar(&region, "region", "us-east-1", "AWS region (default: us-east-1)")
	root.PersistentFlags().StringVar(&accountID, "account", "", "Assume terraform-execute role in this account ID")

	// ── push ─────────────────────────────────────────────────────────────────
	var dryRun bool
	pushCmd := &cobra.Command{
		Use:   "push [repo-dir]",
		Short: "Push all terraform.tfvars files to S3 (default)",
		Example: `  tfvar-backup push my-bucket
  tfvar-backup push my-bucket ../tf_take2 --dry-run`,
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			bucket, repoDir := parseArgs(args)
			repoRoot, err := filepath.Abs(repoDir)
			if err != nil {
				return err
			}
			repoName := gitutil.RepoName(repoRoot)
			ctx := context.Background()
			cfg, err := awsutil.Config(ctx, region, accountID)
			if err != nil {
				return err
			}
			return push(ctx, s3.NewFromConfig(cfg), bucket, repoRoot, repoName, region, dryRun)
		},
	}
	pushCmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show what would be uploaded without doing it")

	// ── pull ─────────────────────────────────────────────────────────────────
	pullCmd := &cobra.Command{
		Use:   "pull <bucket>",
		Short: "Restore all terraform.tfvars files from S3 (run from repo root)",
		Example: `  cd ~/dev/tf_take2 && tfvar-backup pull my-bucket
  tfvar-backup pull my-bucket --diff`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			bucket := args[0]
			repoRoot, err := os.Getwd()
			if err != nil {
				return err
			}
			repoName := gitutil.RepoName(repoRoot)
			ctx := context.Background()
			cfg, err := awsutil.Config(ctx, region, accountID)
			if err != nil {
				return err
			}
			return pull(ctx, s3.NewFromConfig(cfg), bucket, repoRoot, repoName, region, "", showDiff)
		},
	}
	pullCmd.Flags().BoolVar(&showDiff, "diff", false, "Show diff before applying each file")

	// ── pull-file ─────────────────────────────────────────────────────────────
	pullFileCmd := &cobra.Command{
		Use:   "pull-file <bucket> <repo-relative-path>",
		Short: "Restore a single terraform.tfvars file from S3 (run from repo root)",
		Example: `  cd ~/dev/tf_take2 && tfvar-backup pull-file my-bucket deployments/dev/terraform.tfvars
  tfvar-backup pull-file my-bucket deployments/dev/terraform.tfvars --diff`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			bucket := args[0]
			filePath := strings.TrimPrefix(strings.TrimPrefix(args[1], "./"), "/")
			repoRoot, err := os.Getwd()
			if err != nil {
				return err
			}
			repoName := gitutil.RepoName(repoRoot)
			ctx := context.Background()
			cfg, err := awsutil.Config(ctx, region, accountID)
			if err != nil {
				return err
			}
			return pull(ctx, s3.NewFromConfig(cfg), bucket, repoRoot, repoName, region, filePath, showDiff)
		},
	}
	pullFileCmd.Flags().BoolVar(&showDiff, "diff", false, "Show diff before applying")

	// ── list ─────────────────────────────────────────────────────────────────
	listCmd := &cobra.Command{
		Use:   "list <bucket> [repo-dir]",
		Short: "List terraform.tfvars files stored in S3",
		Args:  cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			bucket, repoDir := parseArgs(args)
			repoRoot, err := filepath.Abs(repoDir)
			if err != nil {
				return err
			}
			repoName := gitutil.RepoName(repoRoot)
			ctx := context.Background()
			cfg, err := awsutil.Config(ctx, region, accountID)
			if err != nil {
				return err
			}
			return list(ctx, s3.NewFromConfig(cfg), bucket, repoName)
		},
	}

	root.AddCommand(pushCmd, pullCmd, pullFileCmd, listCmd)

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

// parseArgs returns (bucket, repoDir) from a slice that has 1 or 2 elements.
func parseArgs(args []string) (bucket, repoDir string) {
	bucket = args[0]
	repoDir = "."
	if len(args) > 1 {
		repoDir = args[1]
	}
	return
}

// s3KeyFor returns the S3 object key for a local file path.
func s3KeyFor(repoRoot, repoName, file string) string {
	rel := strings.TrimPrefix(file, repoRoot+string(os.PathSeparator))
	return repoName + "/" + rel
}

// push uploads all terraform.tfvars files under repoRoot to S3.
func push(ctx context.Context, client *s3.Client, bucket, repoRoot, repoName, region string, dryRun bool) error {
	if err := checkBucketExists(ctx, client, bucket); err != nil {
		return err
	}
	files, err := findTFVars(repoRoot)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		fmt.Printf("No terraform.tfvars files found under %s\n", repoRoot)
		return nil
	}

	fmt.Printf("Backing up terraform.tfvars files to s3://%s/\n", bucket)
	if dryRun {
		fmt.Println("(dry-run — no files will be uploaded)")
	}
	fmt.Println()

	for _, file := range files {
		key := s3KeyFor(repoRoot, repoName, file)
		fmt.Printf("  → s3://%s/%s\n", bucket, key)
		if dryRun {
			continue
		}
		if err := uploadFile(ctx, client, bucket, key, file); err != nil {
			return fmt.Errorf("upload %s: %w", file, err)
		}
	}

	fmt.Println()
	if dryRun {
		fmt.Printf("✓ Dry run complete — %d file(s) would be uploaded\n", len(files))
	} else {
		fmt.Printf("✓ Backed up %d terraform.tfvars file(s) to s3://%s/%s/\n", len(files), bucket, repoName)
	}
	return nil
}

// pull restores tfvars from S3. When filePath is non-empty only that one
// file is restored; otherwise all files under the repo prefix are restored.
func pull(ctx context.Context, client *s3.Client, bucket, repoRoot, repoName, region, filePath string, showDiff bool) error {
	if err := checkBucketExists(ctx, client, bucket); err != nil {
		return err
	}
	if filePath != "" {
		key := repoName + "/" + filePath
		fmt.Printf("Restoring s3://%s/%s → %s/%s\n\n", bucket, key, repoRoot, filePath)
		if err := applyOne(ctx, client, bucket, repoRoot, repoName, key, showDiff); err != nil {
			return err
		}
		fmt.Println("\n✓ Restored 1 terraform.tfvars file")
		return nil
	}

	prefix := repoName + "/"
	fmt.Printf("Restoring tfvars from s3://%s/%s → %s\n\n", bucket, prefix, repoRoot)

	keys, err := listKeys(ctx, client, bucket, prefix)
	if err != nil {
		return err
	}
	if len(keys) == 0 {
		fmt.Printf("No terraform.tfvars files found in s3://%s/%s\n", bucket, prefix)
		return nil
	}

	count := 0
	for _, key := range keys {
		if err := applyOne(ctx, client, bucket, repoRoot, repoName, key, showDiff); err != nil {
			return err
		}
		count++
	}

	fmt.Printf("\n✓ Restored %d terraform.tfvars file(s)\n", count)
	return nil
}

// list prints all terraform.tfvars keys stored under the repo prefix.
func list(ctx context.Context, client *s3.Client, bucket, repoName string) error {
	if err := checkBucketExists(ctx, client, bucket); err != nil {
		return err
	}
	prefix := repoName + "/"
	fmt.Printf("Listing tfvars in s3://%s/%s\n", bucket, prefix)

	keys, err := listKeys(ctx, client, bucket, prefix)
	if err != nil {
		return err
	}
	for _, k := range keys {
		fmt.Println(k)
	}
	return nil
}

// checkBucketExists returns a clear error if the bucket does not exist or
// is not accessible, rather than letting a cryptic S3 API error surface later.
func checkBucketExists(ctx context.Context, client *s3.Client, bucket string) error {
	_, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if err != nil {
		return fmt.Errorf(
			"bucket s3://%s not found or not accessible\n\n"+
				"  • Create it first: tfvar-create-buckets %s\n"+
				"  • Check the bucket name and region are correct\n"+
				"  • Verify your AWS credentials have s3:HeadBucket permission",
			bucket, bucket)
	}
	return nil
}

// listKeys returns all S3 keys under prefix that end in terraform.tfvars.
func listKeys(ctx context.Context, client *s3.Client, bucket, prefix string) ([]string, error) {
	var keys []string
	paginator := s3.NewListObjectsV2Paginator(client, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
		Prefix: aws.String(prefix),
	})
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list objects: %w", err)
		}
		for _, obj := range page.Contents {
			if strings.HasSuffix(*obj.Key, "terraform.tfvars") {
				keys = append(keys, *obj.Key)
			}
		}
	}
	sort.Strings(keys)
	return keys, nil
}

// applyOne downloads one S3 key to its local path, optionally diffing first.
func applyOne(ctx context.Context, client *s3.Client, bucket, repoRoot, repoName, key string, showDiff bool) error {
	rel := strings.TrimPrefix(key, repoName+"/")
	localPath := filepath.Join(repoRoot, filepath.FromSlash(rel))

	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		return err
	}

	if showDiff {
		if err := printDiff(ctx, client, bucket, key, localPath); err != nil {
			return err
		}
	}

	fmt.Printf("  ← s3://%s/%s\n       → %s\n", bucket, key, localPath)
	return downloadFile(ctx, client, bucket, key, localPath)
}

// printDiff downloads the S3 object to a temp file and diffs it against the
// local copy (if one exists).
func printDiff(ctx context.Context, client *s3.Client, bucket, key, localPath string) error {
	tmp, err := os.CreateTemp("", "tfvar-diff-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()

	if err := downloadFile(ctx, client, bucket, key, tmp.Name()); err != nil {
		return err
	}

	fmt.Printf("  ── diff: %s ──────────────────────────────\n", localPath)
	if _, err := os.Stat(localPath); os.IsNotExist(err) {
		fmt.Println("  (new file — no local copy exists)")
		content, _ := os.ReadFile(tmp.Name())
		fmt.Println(string(content))
	} else {
		out, _ := exec.Command("diff", "-u", localPath, tmp.Name()).Output()
		if len(out) > 0 {
			fmt.Print(string(out))
		} else {
			fmt.Println("  (no changes)")
		}
	}
	fmt.Println()
	return nil
}

// uploadFile uploads a local file to S3 with SSE-KMS (aws/s3 key).
func uploadFile(ctx context.Context, client *s3.Client, bucket, key, localPath string) error {
	f, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:               aws.String(bucket),
		Key:                  aws.String(key),
		Body:                 f,
		ServerSideEncryption: "aws:kms",
		SSEKMSKeyId:          aws.String("alias/aws/s3"),
	})
	return err
}

// downloadFile downloads an S3 object to a local path.
func downloadFile(ctx context.Context, client *s3.Client, bucket, key, localPath string) error {
	resp, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("get object %s: %w", key, err)
	}
	defer resp.Body.Close()

	var buf bytes.Buffer
	if _, err := io.Copy(&buf, resp.Body); err != nil {
		return err
	}
	return os.WriteFile(localPath, buf.Bytes(), 0o644)
}

// findTFVars returns all terraform.tfvars files under root, excluding
// .terraform and .git directories.
func findTFVars(root string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			name := d.Name()
			if name == ".terraform" || name == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() == "terraform.tfvars" {
			files = append(files, path)
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}
