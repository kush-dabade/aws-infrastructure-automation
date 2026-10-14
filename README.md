# Experiment 6 — Automate and Manage AWS Infrastructure

Infrastructure as Code (IaC) practical using **AWS CloudFormation** to define
infrastructure and the **AWS CLI** to validate, provision, update, verify and
clean it up.

> **Status:** Stage 1 — initial template and local validation.
> Deployment, verification, update and cleanup sections will be added in later stages.

## Architecture

A single CloudFormation stack in `ap-south-1` (Mumbai) containing:

| Resource | Type | Purpose |
|---|---|---|
| `ProjectBucket` | `AWS::S3::Bucket` | Private bucket, SSE-S3 encrypted, all public access blocked, ACLs disabled |
| `ProjectBucketPolicy` | `AWS::S3::BucketPolicy` | Denies any request not made over HTTPS |

```
 AWS CLI ──► CloudFormation stack ──► S3 bucket  (encrypted, private)
                                  └─► Bucket policy (HTTPS only)
```

**Security by default**

- Encryption at rest with S3-managed keys (`AES256`).
- All four S3 Block Public Access settings enabled.
- Object ownership `BucketOwnerEnforced` (ACLs disabled).
- Encryption in transit enforced by denying `aws:SecureTransport = false`.
- No credentials, access keys or account IDs in the code. The account ID is
  taken from the `AWS::AccountId` pseudo parameter at deploy time.

**Cost:** an empty S3 bucket and a CloudFormation stack cost nothing. Storing a
few small test files costs a fraction of a cent.

## Repository layout

```
.
├── README.md
└── templates/
    └── s3-bucket.yaml      # CloudFormation template
```

## Template overview

| Section | Contents |
|---|---|
| `Parameters` | `ProjectName` (default `exp6-iac`), `Environment` (`dev` or `test`), `Owner` |
| `Resources` | The bucket and its bucket policy |
| `Outputs` | `BucketName`, `BucketArn`, `BucketRegion` |

Bucket name format: `<ProjectName>-<Environment>-<AccountId>-<Region>`,
for example `exp6-iac-dev-123456789012-ap-south-1`. Including the account ID and
region keeps the name globally unique without hard-coding anything.

## Prerequisites

- AWS CLI v2 configured with credentials for your own account (`aws configure`
  or `aws sso login`). Never commit credentials to this repository.
- Python 3 with `pip`, for the optional `cfn-lint` linter.

## Stage 1 — Validate the template

Run these from the repository root. **None of them create AWS resources.**

### 1. Review the template

```bash
cat templates/s3-bucket.yaml
```

Check that it contains only the bucket and bucket policy, has no hard-coded
account IDs or keys, and has encryption and public access blocking enabled.

### 2. Lint locally with cfn-lint (offline)

`cfn-lint` checks the template against the CloudFormation resource
specification: property names, types, allowed values and best practices.

```bash
python3 -m pip install --user cfn-lint   # one-time install
cfn-lint templates/s3-bucket.yaml
```

Expected result: no output and exit code `0`.

```bash
echo $?
```

### 3. Validate with the CloudFormation API

This sends the template to CloudFormation for a syntax check. It is free and
**does not create a stack or any resources**.

```bash
aws cloudformation validate-template \
  --region ap-south-1 \
  --template-body file://templates/s3-bucket.yaml
```

Expected result: JSON listing the three parameters (`ProjectName`,
`Environment`, `Owner`) and the template description. No `Capabilities` should
be listed, because the template creates no IAM resources.

### Test cases — Stage 1

| # | Test | Command | Expected |
|---|---|---|---|
| 1.1 | Template passes linting | `cfn-lint templates/s3-bucket.yaml` | No findings, exit code `0` |
| 1.2 | Template is valid CloudFormation | `aws cloudformation validate-template ...` | Parameters and description returned |
| 1.3 | No secrets or account IDs in the code | See command below | Prints `No secrets found` |

Test 1.3 command:

```bash
grep -rnE "AKIA|aws_secret|[0-9]{12}" templates/ || echo "No secrets found"
```

### Screenshots — Stage 1

1. The template open in an editor or printed with `cat`.
2. `cfn-lint` output with exit code `0`.
3. `validate-template` JSON output.
