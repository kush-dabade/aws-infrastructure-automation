# Experiment 6 — Automate and Manage AWS Infrastructure

An Infrastructure as Code (IaC) practical using **AWS CloudFormation** to define infrastructure and the **AWS CLI** to validate, provision, update, and verify resources.

> **Status:** Initial deployment (`CREATE_COMPLETE`), versioning update (`UPDATE_COMPLETE`), and drift detection (`IN_SYNC`) are complete in `ap-south-1`. Cleanup is pending; the CloudFormation stack and S3 bucket still exist.

## Objective

Implement a repeatable Infrastructure as Code workflow using AWS CloudFormation and the AWS CLI. The practical demonstrates infrastructure provisioning, configuration updates, verification, and drift detection. Resource cleanup remains pending.

## Requirements

| Requirement | How it is met |
|---|---|
| CloudFormation as the IaC tool | `templates/s3-bucket.yaml` defines the infrastructure. |
| AWS CLI for resource management | Used for validation, deployment, updates, verification, and drift detection. |
| Repeatable and parameterised | Uses `ProjectName`, `Environment`, and `Owner` parameters. |
| Reviewed changes | Create and update operations use CloudFormation change sets. |
| Secure configuration | Encryption, public access blocking, disabled ACLs, and an HTTPS-only bucket policy. |
| No credentials in code | The template uses the `AWS::AccountId` pseudo parameter; access keys are not stored in the repository. |
| Minimal infrastructure | One S3 bucket and its bucket policy; no VPC, EC2, NAT Gateway, or RDS resources. |
| Version control | Git and GitHub are used to track implementation changes. |

**Tools:** AWS CloudFormation, AWS CLI v2, Bash, Git, and GitHub.

**Region:** `ap-south-1` (Mumbai).

## Architecture

The CloudFormation stack `exp6-iac-dev-stack` manages two resources.

```text
Developer
   |
   | AWS CLI: create change set -> review -> execute
   v
CloudFormation stack: exp6-iac-dev-stack
   |
   |-- ProjectBucket
   |      AWS::S3::Bucket
   |      Encrypted, private, versioned, and tagged
   |
   `-- ProjectBucketPolicy
          AWS::S3::BucketPolicy
          Denies requests made without HTTPS
```

### Security configuration

| Control | Configuration |
|---|---|
| Encryption at rest | SSE-S3 (`AES256`) |
| Block Public Access | All four settings enabled: `BlockPublicAcls`, `BlockPublicPolicy`, `IgnorePublicAcls`, and `RestrictPublicBuckets` |
| Object ownership | `BucketOwnerEnforced`; ACLs disabled |
| Encryption in transit | Bucket policy denies requests where `aws:SecureTransport` is `false` |
| Versioning | Enabled through the Stage 3 update |
| Tags | `Project`, `Environment`, `Owner`, and `ManagedBy=CloudFormation` |

### Template structure

| Section | Contents |
|---|---|
| `Parameters` | `ProjectName` (default `exp6-iac`), `Environment` (allowed values `dev` or `test`; default `dev`), and `Owner` (default `kush`) |
| `Resources` | `ProjectBucket` and `ProjectBucketPolicy` |
| `Outputs` | `BucketName`, `BucketArn`, and `BucketRegion` |

The bucket name follows the pattern `<ProjectName>-<Environment>-<AccountId>-<Region>`. The account ID and region are derived dynamically rather than hard-coded in the template.

The bucket has a deletion policy of `Delete`. CloudFormation can delete it only after its contents, including all stored object versions and delete markers, have been removed.

## Repository Layout

```text
.
├── README.md
├── scripts/
│   ├── config.sh
│   └── deploy.sh
└── templates/
    └── s3-bucket.yaml
```

- `scripts/config.sh` contains shared settings and helper functions. Defaults include region `ap-south-1`, stack name `exp6-iac-dev-stack`, and parameters `ProjectName=exp6-iac`, `Environment=dev`, and `Owner=kush`.
- `scripts/deploy.sh` creates a new stack through a reviewed CloudFormation change set. It displays the proposed changes and requires the user to type `yes` before executing them.

### Overriding configuration for a single run

Settings in `scripts/config.sh` (`AWS_REGION`, `PROJECT_NAME`, `ENVIRONMENT`, `OWNER`, and `STACK_NAME`) can be overridden for a single run by setting environment variables on the command line, without editing the file:

```bash
OWNER=someone ./scripts/deploy.sh
```

The override applies only to that command. The stack name defaults to `<PROJECT_NAME>-<ENVIRONMENT>-stack`, so overriding `PROJECT_NAME` or `ENVIRONMENT` targets a different stack and bucket. `ENVIRONMENT` must be `dev` or `test`, because the template rejects other values.

### Deployment safety checks

The deployment script checks that the stack does not already exist. If a change set is cancelled or fails, it removes the empty placeholder stack only when its safety checks confirm that the stack was created by that run, remains in `REVIEW_IN_PROGRESS`, has never been executed, and contains no resources. Otherwise, it reports the issue and exits with a non-zero code.

## Prerequisites

- AWS CLI v2 configured for the intended AWS account using `aws configure` or `aws sso login`.
- Bash and Git.
- Python 3 and `cfn-lint` for optional offline template linting.

Never commit AWS credentials or secret keys to the repository.

## Implementation

Run commands from the repository root.

### Stage 1 — Validate the template

These commands validate the template without creating AWS resources.

```bash
cat templates/s3-bucket.yaml

# Optional: install the template linter
python3 -m pip install --user cfn-lint

# Lint the template
cfn-lint templates/s3-bucket.yaml

# Validate through the CloudFormation API
aws cloudformation validate-template \
  --region ap-south-1 \
  --template-body file://templates/s3-bucket.yaml

# Scan the template for likely credentials or hard-coded account IDs
grep -rnE 'AKIA|aws_secret|[0-9]{12}' templates/ \
  || echo "No matches found"
```

The linter and secret scan are separate checks. A clean scan does not, by itself, prove that a repository contains no secrets.

### Stage 2 — Deploy with a change set

Check the shell scripts and run the deployment script.

```bash
bash -n scripts/config.sh &&
bash -n scripts/deploy.sh &&
echo "Syntax OK"

./scripts/deploy.sh
```

The create change set proposes two resources: `ProjectBucket` and `ProjectBucketPolicy`. After confirmation, the script executes the change set, waits for `CREATE_COMPLETE`, and displays the stack outputs and recent events.

If creation fails, CloudFormation rolls back and the stack normally ends in `ROLLBACK_COMPLETE`. A stack in this state cannot be updated; it can only be deleted. The script displays recent events; they can also be inspected directly to find the `CREATE_FAILED` reason:

```bash
aws cloudformation describe-stack-events \
  --region ap-south-1 \
  --stack-name exp6-iac-dev-stack \
  --max-items 20 \
  --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
  --output table
```

Correct the cause, confirm the stack state, and delete the failed stack only when it is safe to remove. Then re-run the deployment script.

```bash
aws cloudformation delete-stack \
  --region ap-south-1 \
  --stack-name exp6-iac-dev-stack
```

### Stage 3 — Update the stack to enable versioning

Versioning was added to `ProjectBucket` in `templates/s3-bucket.yaml`:

```yaml
      VersioningConfiguration:
        Status: Enabled
```

Validate the updated template using Stage 1. Then set the variables and inspect the bucket's versioning state before the update.

```bash
REGION=ap-south-1
STACK=exp6-iac-dev-stack
CHANGE_SET=enable-s3-versioning

BUCKET=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
  --output text)

echo "$BUCKET"

aws s3api get-bucket-versioning \
  --region "$REGION" \
  --bucket "$BUCKET"
```

Expected: no versioning status is returned.

Create the update change set while retaining the existing parameters.

```bash
aws cloudformation create-change-set \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET" \
  --change-set-type UPDATE \
  --template-body file://templates/s3-bucket.yaml \
  --parameters \
    ParameterKey=ProjectName,UsePreviousValue=true \
    ParameterKey=Environment,UsePreviousValue=true \
    ParameterKey=Owner,UsePreviousValue=true \
  --description "Enable versioning on ProjectBucket"

aws cloudformation wait change-set-create-complete \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET"
```

Review the proposed actions and whether any resource requires replacement.

```bash
aws cloudformation describe-change-set \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET" \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' \
  --output table

aws cloudformation describe-change-set \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET" \
  --query 'Changes[].ResourceChange.Details[].Target.[Attribute,Name,RequiresRecreation]' \
  --output table
```

> **Replacement warning:** If any row shows `Replacement = True` (or `Conditional`), CloudFormation may create a new bucket and delete the existing one, putting its contents at risk. Do not execute such a change set without reviewing the consequences.

If the change set shows unexpected actions, an unwanted replacement, or should not be applied for any other reason, discard it instead of executing it. Deleting a change set does not change the stack or its resources.

```bash
aws cloudformation delete-change-set \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET"
```

Execute the change set only after confirming that the proposed actions are expected and that no resource replacement is required.

```bash
aws cloudformation execute-change-set \
  --region "$REGION" \
  --stack-name "$STACK" \
  --change-set-name "$CHANGE_SET"

aws cloudformation wait stack-update-complete \
  --region "$REGION" \
  --stack-name "$STACK"

aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query 'Stacks[0].StackStatus' \
  --output text
```

The observed result was `UPDATE_COMPLETE`. Both `ProjectBucket` and `ProjectBucketPolicy` appeared as `Modify` actions with no replacement. The policy's appearance in the change set may be related to its references to the bucket; this is an explanation, not a separately verified cause.

If an update fails, CloudFormation rolls back to the previous configuration and the stack normally ends in `UPDATE_ROLLBACK_COMPLETE`. Inspect the stack events for the `UPDATE_FAILED` reason:

```bash
aws cloudformation describe-stack-events \
  --region "$REGION" \
  --stack-name "$STACK" \
  --max-items 15 \
  --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
  --output table
```

### Stage 4 — Detect drift

Drift detection compares supported live resource properties against the CloudFormation template. Start detection and check the result until detection completes.

```bash
DETECTION_ID=$(aws cloudformation detect-stack-drift \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query StackDriftDetectionId \
  --output text)

aws cloudformation describe-stack-drift-detection-status \
  --region "$REGION" \
  --stack-drift-detection-id "$DETECTION_ID" \
  --query '[DetectionStatus,StackDriftStatus,DriftedStackResourceCount]' \
  --output table

aws cloudformation describe-stack-resource-drifts \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query 'StackResourceDrifts[].[LogicalResourceId,ResourceType,StackResourceDriftStatus]' \
  --output table
```

The recorded drift detection result was `DETECTION_COMPLETE`, with the stack `IN_SYNC` and zero drifted resources.

## Verification and Results

### Verification commands

With `REGION`, `STACK`, and `BUCKET` set as in Stage 3, the following read-only commands inspect the stack and bucket configuration.

```bash
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query 'Stacks[0].StackStatus' \
  --output text

aws cloudformation describe-stack-resources \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query 'StackResources[].[LogicalResourceId,ResourceType,ResourceStatus]' \
  --output table

aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table

aws s3api get-bucket-versioning \
  --region "$REGION" --bucket "$BUCKET"

aws s3api get-bucket-encryption \
  --region "$REGION" --bucket "$BUCKET"

aws s3api get-public-access-block \
  --region "$REGION" --bucket "$BUCKET"

aws s3api get-bucket-ownership-controls \
  --region "$REGION" --bucket "$BUCKET"

aws s3api get-bucket-policy \
  --region "$REGION" --bucket "$BUCKET" \
  --query Policy --output text

aws s3api get-bucket-tagging \
  --region "$REGION" --bucket "$BUCKET"
```

### Verified results

| Check | Recorded result |
|---|---|
| Region | `ap-south-1` (Mumbai) |
| CloudFormation stack | `exp6-iac-dev-stack` |
| S3 bucket | `exp6-iac-dev-851226124537-ap-south-1` |
| Initial deployment | `CREATE_COMPLETE` |
| Update change set | `enable-s3-versioning`; both resources modified without replacement |
| Versioning update | `UPDATE_COMPLETE` |
| Versioning | `Enabled` |
| Encryption | SSE-S3 (`AES256`) |
| Block Public Access | All four settings `true` |
| Object ownership | `BucketOwnerEnforced` |
| Tags | `Project=exp6-iac`, `Environment=dev`, `Owner=kush`, `ManagedBy=CloudFormation` |
| Drift detection | `DETECTION_COMPLETE`, `IN_SYNC`, zero drifted resources |
| Cleanup | Pending |

### Expected behaviour not separately recorded

The following describes the intended behaviour of the scripts and checks; it is not a claim that each scenario was separately tested.

| Check | Expected behaviour |
|---|---|
| `cfn-lint` | Reports template findings, if any |
| Secret scan | Reports matching patterns or prints the no-match message |
| Deployment confirmation other than `yes` | Does not execute the create change set; applies the script's guarded cancellation handling |
| Deployment when the stack already exists | Refuses to create another stack with the same name |
| Versioning check before the update | Returns no versioning status |
| Bucket name after the update | Remains unchanged because the bucket was not replaced |

## Benefits

- **Repeatability:** Infrastructure is defined in a template rather than created entirely by hand.
- **Reviewability:** Change sets show proposed resource changes before execution.
- **Version control:** Git tracks changes to the infrastructure definition and scripts.
- **Security:** Encryption, public access blocking, disabled ACLs, and HTTPS enforcement are defined as part of the infrastructure.
- **Auditing:** CloudFormation stack events and drift detection provide information about resource operations and configuration consistency.
- **Rollback support:** CloudFormation attempts to roll back failed stack operations where supported.

## Limitations

- **Limited scope:** The practical provisions one S3 bucket and its bucket policy; networking and compute infrastructure are not covered.
- **Manual updates:** `scripts/deploy.sh` creates new stacks. The versioning update was performed separately through the AWS CLI.
- **Versioning and cleanup:** Enabling versioning preserves older object versions. Every version and delete marker must be removed before the bucket can be deleted.
- **Bucket name changes:** Changing parameters that determine the bucket name can require resource replacement.
- **Point-in-time drift detection:** Drift detection reports the configuration at the time the check runs.
- **Cleanup automation:** A dedicated cleanup script has not yet been implemented.

## Cost Considerations

- The infrastructure consists of an S3 bucket and a bucket policy. No VPC, EC2 instance, NAT Gateway, RDS instance, or load balancer was created.
- CloudFormation does not add a separate management charge for these resource types; the underlying AWS resources may incur charges.
- S3 charges can apply to stored data, requests, and other applicable usage. With versioning enabled, older object versions also contribute to stored data.
- After successful cleanup, charges associated with the deleted resources should stop accruing, provided no billable data or other resources remain. Final billing can reflect earlier usage.

## Cleanup

**Status: pending.** The stack `exp6-iac-dev-stack` and bucket `exp6-iac-dev-851226124537-ap-south-1` have not been deleted.

Because versioning is enabled, deleting an object normally creates a delete marker while retaining earlier versions. **Every object version and every delete marker must be removed before CloudFormation can delete the bucket.** Otherwise, bucket deletion can fail and leave the stack in `DELETE_FAILED`.

First define the required variables and inspect the bucket contents. This check is read-only.

```bash
REGION=ap-south-1
STACK=exp6-iac-dev-stack
BUCKET=exp6-iac-dev-851226124537-ap-south-1

aws s3api list-object-versions \
  --region "$REGION" \
  --bucket "$BUCKET" \
  --query '{Versions: length(Versions || `[]`), DeleteMarkers: length(DeleteMarkers || `[]`)}'
```

Do not delete anything until the returned versions and delete markers have been inspected. If the bucket contains any, remove every version and delete marker, then verify that both counts are zero.

Only after confirming the bucket is empty should the stack be deleted:

```bash
aws cloudformation delete-stack \
  --region "$REGION" \
  --stack-name "$STACK"

aws cloudformation wait stack-delete-complete \
  --region "$REGION" \
  --stack-name "$STACK"
```

Finally, verify that the stack no longer exists. Cleanup should be marked complete only after the deletion succeeds.

## Conclusion

This practical demonstrated an Infrastructure as Code workflow using AWS CloudFormation and the AWS CLI in `ap-south-1`. The template provisioned an encrypted, private S3 bucket with an HTTPS-only bucket policy. The stack reached `CREATE_COMPLETE`, and versioning was enabled through a reviewed change set, reaching `UPDATE_COMPLETE` without replacing either resource. AWS CLI checks confirmed the bucket's versioning, encryption, public access settings, ownership controls, and tags. Drift detection reported `IN_SYNC` with zero drifted resources. **Cleanup remains pending** and requires removing all object versions and delete markers before deleting the versioned bucket and its CloudFormation stack.
