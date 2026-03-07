package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/mpechner/tfvar_backup/internal/awsutil"
	"github.com/mpechner/tfvar_backup/internal/version"
	"github.com/spf13/cobra"
)

func main() {
	var (
		region        string
		accountID     string
		loggingBucket string
	)

	cmd := &cobra.Command{
		Use:     "tfvar-create-buckets <tfvars-bucket>",
		Short:   "Create the S3 buckets required for tfvars backup",
		Version: version.String(),
		Long: `Create the two S3 buckets required for tfvars backup. Idempotent — safe to run multiple times.

Buckets created:
  <tfvars-bucket>            Versioned, SSE-KMS (aws/s3), noncurrent versions expire after 90 days
  <tfvars-bucket>-objectlogs Server-access log target, SSE-KMS (aws/s3)

Logging prefix format:
  <git-repo-name>/[YYYY]-[MM]-[DD]-[hh]-[mm]-[ss]-[UniqueString]`,
		Example: `  tfvar-create-buckets my-tfvars-backup
  tfvar-create-buckets my-tfvars-backup --region us-west-2
  tfvar-create-buckets my-tfvars-backup --account 123456789012 --logging my-custom-logs`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			tfvarsBucket := args[0]
			if loggingBucket == "" {
				loggingBucket = tfvarsBucket + "-objectlogs"
			}

			ctx := context.Background()
			cfg, err := awsutil.Config(ctx, region, accountID)
			if err != nil {
				return err
			}

			repoName := detectRepoName()
			loggingPrefix := repoName + "/"

			client := s3.NewFromConfig(cfg)

			fmt.Printf("\n── Logging bucket: s3://%s ──\n", loggingBucket)
			if err := setupBucket(ctx, client, loggingBucket, region, false); err != nil {
				return err
			}
			fmt.Println("  [ok] Logging bucket ready.")

			fmt.Printf("\n── Backup bucket: s3://%s ──\n", tfvarsBucket)
			if err := setupBucket(ctx, client, tfvarsBucket, region, true); err != nil {
				return err
			}
			if err := enableLogging(ctx, client, tfvarsBucket, loggingBucket, loggingPrefix); err != nil {
				return err
			}
			fmt.Println("  [ok] Backup bucket ready.")

			fmt.Printf(`
✓ All done.

  Backup bucket : s3://%s
    versioning  : enabled
    encryption  : SSE-KMS (aws/s3)
    lifecycle   : noncurrent versions expire after 90 days
    logging  →  : s3://%s/%s

  Logging bucket: s3://%s
    encryption  : SSE-KMS (aws/s3)
    public access: blocked
`, tfvarsBucket, loggingBucket, loggingPrefix, loggingBucket)
			return nil
		},
	}

	cmd.Flags().StringVar(&region, "region", "us-east-1", "AWS region for both buckets")
	cmd.Flags().StringVar(&accountID, "account", "", "Assume terraform-execute role in this account ID")
	cmd.Flags().StringVar(&loggingBucket, "logging", "", "Access-log bucket name (default: <tfvars-bucket>-objectlogs)")

	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}

// detectRepoName returns the repo name from the git remote of the current
// working directory, falling back to the directory basename.
func detectRepoName() string {
	cwd, _ := os.Getwd()
	out, err := exec.Command("git", "-C", cwd, "remote", "get-url", "origin").Output()
	if err == nil {
		raw := strings.TrimSpace(string(out))
		if idx := strings.LastIndexAny(raw, "/:"); idx >= 0 {
			raw = raw[idx+1:]
		}
		raw = strings.TrimSuffix(raw, ".git")
		if raw != "" {
			return raw
		}
	}
	return filepath.Base(cwd)
}

// setupBucket creates and configures a bucket. When versioned is true,
// versioning and the noncurrent-version lifecycle rule are also applied.
func setupBucket(ctx context.Context, client *s3.Client, bucket, region string, versioned bool) error {
	if err := createBucketIfMissing(ctx, client, bucket, region); err != nil {
		return err
	}
	if err := blockPublicAccess(ctx, client, bucket); err != nil {
		return err
	}
	if err := enableEncryption(ctx, client, bucket); err != nil {
		return err
	}
	if versioned {
		if err := enableVersioning(ctx, client, bucket); err != nil {
			return err
		}
		if err := applyLifecycle(ctx, client, bucket); err != nil {
			return err
		}
	}
	return nil
}

func createBucketIfMissing(ctx context.Context, client *s3.Client, bucket, region string) error {
	_, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if err == nil {
		fmt.Printf("  [skip] Bucket already exists: s3://%s\n", bucket)
		return nil
	}

	fmt.Printf("  [create] Creating bucket: s3://%s (%s)\n", bucket, region)
	input := &s3.CreateBucketInput{Bucket: aws.String(bucket)}
	if region != "us-east-1" {
		input.CreateBucketConfiguration = &types.CreateBucketConfiguration{
			LocationConstraint: types.BucketLocationConstraint(region),
		}
	}
	if _, err := client.CreateBucket(ctx, input); err != nil {
		return fmt.Errorf("create bucket %s: %w", bucket, err)
	}
	fmt.Printf("  [ok] Created: s3://%s\n", bucket)
	return nil
}

func blockPublicAccess(ctx context.Context, client *s3.Client, bucket string) error {
	fmt.Printf("  [config] Blocking public access on s3://%s...\n", bucket)
	t := true
	_, err := client.PutPublicAccessBlock(ctx, &s3.PutPublicAccessBlockInput{
		Bucket: aws.String(bucket),
		PublicAccessBlockConfiguration: &types.PublicAccessBlockConfiguration{
			BlockPublicAcls:       &t,
			IgnorePublicAcls:      &t,
			BlockPublicPolicy:     &t,
			RestrictPublicBuckets: &t,
		},
	})
	return err
}

func enableEncryption(ctx context.Context, client *s3.Client, bucket string) error {
	fmt.Printf("  [config] Enabling SSE-KMS (aws/s3) encryption on s3://%s...\n", bucket)
	t := true
	_, err := client.PutBucketEncryption(ctx, &s3.PutBucketEncryptionInput{
		Bucket: aws.String(bucket),
		ServerSideEncryptionConfiguration: &types.ServerSideEncryptionConfiguration{
			Rules: []types.ServerSideEncryptionRule{
				{
					ApplyServerSideEncryptionByDefault: &types.ServerSideEncryptionByDefault{
						SSEAlgorithm:   types.ServerSideEncryptionAwsKms,
						KMSMasterKeyID: aws.String("alias/aws/s3"),
					},
					BucketKeyEnabled: &t,
				},
			},
		},
	})
	return err
}

func enableVersioning(ctx context.Context, client *s3.Client, bucket string) error {
	fmt.Printf("  [config] Enabling versioning on s3://%s...\n", bucket)
	_, err := client.PutBucketVersioning(ctx, &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{
			Status: types.BucketVersioningStatusEnabled,
		},
	})
	return err
}

func applyLifecycle(ctx context.Context, client *s3.Client, bucket string) error {
	fmt.Printf("  [config] Applying lifecycle rule (noncurrent versions expire after 90 days) on s3://%s...\n", bucket)
	days := int32(90)
	emptyPrefix := ""
	_, err := client.PutBucketLifecycleConfiguration(ctx, &s3.PutBucketLifecycleConfigurationInput{
		Bucket: aws.String(bucket),
		LifecycleConfiguration: &types.BucketLifecycleConfiguration{
			Rules: []types.LifecycleRule{
				{
					ID:     aws.String("expire-noncurrent-versions-90d"),
					Status: types.ExpirationStatusEnabled,
					Filter: &types.LifecycleRuleFilter{Prefix: &emptyPrefix},
					NoncurrentVersionExpiration: &types.NoncurrentVersionExpiration{
						NoncurrentDays: &days,
					},
				},
			},
		},
	})
	return err
}

func enableLogging(ctx context.Context, client *s3.Client, bucket, loggingBucket, prefix string) error {
	fmt.Printf("  [config] Enabling server access logging → s3://%s/%s...\n", loggingBucket, prefix)
	_, err := client.PutBucketLogging(ctx, &s3.PutBucketLoggingInput{
		Bucket: aws.String(bucket),
		BucketLoggingStatus: &types.BucketLoggingStatus{
			LoggingEnabled: &types.LoggingEnabled{
				TargetBucket: aws.String(loggingBucket),
				TargetPrefix: aws.String(prefix),
			},
		},
	})
	return err
}
