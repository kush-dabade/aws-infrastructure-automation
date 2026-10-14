# Experiment 6 — Automate and Manage AWS Infrastructure

Infrastructure as Code (IaC) practical using **AWS CloudFormation** to define
infrastructure and the **AWS CLI** to validate, provision, update, verify and
clean it up.

> **Status:** Stage 2 — deployment with a change set.
> Verification, update and cleanup sections will be added in later stages.

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
├── scripts/
│   ├── config.sh           # Shared settings (region, stack name, parameters) and helpers
│   └── deploy.sh           # Creates the stack through a reviewed change set
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

## Stage 2 — Deploy with a change set

A **change set** is CloudFormation's preview of what it will do. `deploy.sh`
creates one, shows it, and only creates resources after you type `yes`.

### Settings

Defaults live in `scripts/config.sh`:

| Setting | Default |
|---|---|
| Region | `ap-south-1` |
| Stack name | `exp6-iac-dev-stack` |
| Parameters | `ProjectName=exp6-iac`, `Environment=dev`, `Owner=kush` |

Any setting can be overridden for one run, for example
`OWNER=someone ./scripts/deploy.sh`. The scripts never print credentials or
change your AWS configuration.

### 1. Review and syntax-check the scripts

```bash
cat scripts/config.sh scripts/deploy.sh
bash -n scripts/config.sh && bash -n scripts/deploy.sh && echo "Syntax OK"
```

### 2. Run the deployment

```bash
./scripts/deploy.sh
```

What the script does:

1. Prints the account ID, region, stack name and parameters, so you can check
   you are in the right account.
2. Checks that the stack does not already exist.
3. Creates a `CREATE` change set and waits for it to be ready.
4. Shows the proposed changes.
5. Asks: `Type "yes" to continue:`. Anything else cancels.
6. Executes the change set, waits for `CREATE_COMPLETE`, and prints the stack
   outputs and recent events.

### Expected output

The proposed changes should list exactly two resources being added:

```
|  Add  |  ProjectBucket        |  AWS::S3::Bucket        |  None  |
|  Add  |  ProjectBucketPolicy  |  AWS::S3::BucketPolicy  |  None  |
```

After you type `yes`:

```
==> Stack created: CREATE_COMPLETE

==> Stack outputs
|  BucketArn    |  arn:aws:s3:::exp6-iac-dev-<account-id>-ap-south-1  |
|  BucketName   |  exp6-iac-dev-<account-id>-ap-south-1               |
|  BucketRegion |  ap-south-1                                         |
```

followed by a table of recent events ending in `CREATE_COMPLETE` for both
resources and the stack.

### If you cancel or something fails

Creating a `CREATE` change set makes an empty placeholder stack with status
`REVIEW_IN_PROGRESS`. If you cancel, press Ctrl+C or the change set fails,
the script removes that placeholder and waits for the deletion to finish.
It only does this when **all** of these are true:

- it is the exact stack ID created by this run, with the configured stack name;
- its status is still `REVIEW_IN_PROGRESS`;
- the change set was never executed;
- the stack contains no resources.

If any check fails, or the deletion does not finish, the script deletes
nothing more and prints a warning with the command to run manually. The
original error is repeated at the end so it is not lost, and the script exits
with a non-zero code.

If the stack itself fails to create (status `ROLLBACK_COMPLETE`), the script
shows the last 20 events. Look for `CREATE_FAILED` and its reason, fix the
cause, delete the stack, then re-run:

```bash
aws cloudformation delete-stack --region ap-south-1 --stack-name exp6-iac-dev-stack
```

### Test cases — Stage 2

| # | Test | Action | Expected |
|---|---|---|---|
| 2.1 | Scripts are valid Bash | `bash -n` on both scripts | `Syntax OK` |
| 2.2 | Change set previews changes | Run `deploy.sh` | Two `Add` actions, no replacement |
| 2.3 | Cancelling creates nothing | Run `deploy.sh`, type `no` | `Cancelled`, placeholder removed, exit code `0` |
| 2.4 | Confirmed deployment succeeds | Run `deploy.sh`, type `yes` | `CREATE_COMPLETE` and three outputs |
| 2.5 | Re-running is blocked | Run `deploy.sh` again | `already exists with status CREATE_COMPLETE`, exit code `1` |

Check the exit code after each run with `echo $?`.

### Screenshots — Stage 2

1. `bash -n` output showing `Syntax OK`.
2. Pre-flight output showing account, region, stack and parameters.
3. The proposed changes table and the `yes` prompt.
4. (Optional) A cancelled run showing the placeholder being removed.
5. `CREATE_COMPLETE` with the stack outputs and recent events.
6. AWS Console: CloudFormation → Stacks → `exp6-iac-dev-stack` → **Change sets** tab
   and **Events** tab.
7. AWS Console: S3 → the new bucket → **Properties** (default encryption) and
   **Permissions** (Block Public Access all **On**, bucket policy).
