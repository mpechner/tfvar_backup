// Package awsutil provides helpers for building AWS SDK v2 clients,
// including optional cross-account role assumption.
package awsutil

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// Config returns an AWS config for the given region.  When accountID is
// non-empty the config uses temporary credentials obtained by assuming
// arn:aws:iam::<accountID>:role/terraform-execute via STS.
func Config(ctx context.Context, region, accountID string) (aws.Config, error) {
	base, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return aws.Config{}, fmt.Errorf("load AWS config: %w", err)
	}

	// Verify credentials are actually available before making any API calls.
	// This produces a clear message instead of a cryptic SDK error later.
	if _, err := base.Credentials.Retrieve(ctx); err != nil {
		return aws.Config{}, fmt.Errorf(
			"no AWS credentials found: %w\n\n"+
				"Configure credentials via one of:\n"+
				"  • ~/.aws/credentials  or  ~/.aws/config\n"+
				"  • Environment variables: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY\n"+
				"  • IAM instance profile (EC2) or task role (ECS)\n"+
				"  • OIDC role: set OIDC_ROLE_ARN in GitHub Actions variables\n"+
				"    Run scripts/setup-iam.sh to create the role (--help for usage)",
			err,
		)
	}

	if accountID == "" {
		return base, nil
	}

	roleARN := fmt.Sprintf("arn:aws:iam::%s:role/terraform-execute", accountID)
	fmt.Printf("Assuming role %s...\n", roleARN)

	stsClient := sts.NewFromConfig(base)
	creds := stscreds.NewAssumeRoleProvider(stsClient, roleARN, func(o *stscreds.AssumeRoleOptions) {
		o.RoleSessionName = "tfvar-backup"
	})

	assumed, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(region),
		config.WithCredentialsProvider(aws.NewCredentialsCache(creds)),
	)
	if err != nil {
		return aws.Config{}, fmt.Errorf("build assumed-role config: %w", err)
	}
	return assumed, nil
}
