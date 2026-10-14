# shellcheck shell=bash
# Shared settings and helper functions for the deployment scripts.
# This file is sourced by other scripts; it is not run directly.
#
# Any setting can be overridden for a single run without editing this file:
#   ENVIRONMENT=test OWNER=someone ./scripts/deploy.sh

# --- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${REPO_ROOT}/templates/s3-bucket.yaml"

# --- Deployment settings ---------------------------------------------------
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_NAME="${PROJECT_NAME:-exp6-iac}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
OWNER="${OWNER:-kush}"
STACK_NAME="${STACK_NAME:-${PROJECT_NAME}-${ENVIRONMENT}-stack}"

# Template parameters, in the format expected by `aws cloudformation --parameters`.
STACK_PARAMETERS=(
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"
  "ParameterKey=Environment,ParameterValue=${ENVIRONMENT}"
  "ParameterKey=Owner,ParameterValue=${OWNER}"
)

# Stop the AWS CLI opening output in a pager (affects this script only,
# not your AWS configuration).
export AWS_PAGER=""

# --- Helpers ---------------------------------------------------------------
info()    { printf '\n==> %s\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*" >&2; }
die()     { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Exit unless a command is installed.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed or not on PATH."
}

# Ask a question and return success only if the user types exactly "yes".
confirm() {
  local reply=""
  printf '\n%s Type "yes" to continue: ' "$1"
  read -r reply || true
  [[ "${reply}" == "yes" ]]
}

# Wrapper so every CloudFormation call uses the configured region.
cfn() {
  aws cloudformation --region "${AWS_REGION}" "$@"
}

# Print the stack status, or "DOES_NOT_EXIST". Exits on any other error
# (for example expired credentials) instead of guessing.
stack_status() {
  local output
  if output="$(cfn describe-stacks --stack-name "${STACK_NAME}" \
                 --query 'Stacks[0].StackStatus' --output text 2>&1)"; then
    printf '%s\n' "${output}"
  elif [[ "${output}" == *"does not exist"* ]]; then
    printf 'DOES_NOT_EXIST\n'
  else
    die "Could not read stack status: ${output}"
  fi
}

# Show the most recent stack events, newest first.
show_recent_events() {
  local count="${1:-15}"
  cfn describe-stack-events --stack-name "${STACK_NAME}" --max-items "${count}" \
    --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
    --output table
}

# Show the stack outputs.
show_outputs() {
  cfn describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
}
