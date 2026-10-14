#!/usr/bin/env bash
# Create the CloudFormation stack using a change set.
#
# Steps:
#   1. Check tools, template and AWS identity
#   2. Make sure the stack does not already exist
#   3. Create a CREATE change set and show the proposed changes
#   4. Ask for confirmation ("yes") before executing it
#   5. Wait for stack creation, then print outputs and recent events
#
# Usage: ./scripts/deploy.sh

set -euo pipefail

# shellcheck source=scripts/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

CHANGE_SET_NAME="create-$(date +%Y%m%d-%H%M%S)"
CHANGE_SET_ID=""        # ARN returned by create-change-set
CREATED_STACK_ID=""     # Stack ARN returned by create-change-set
CHANGE_SET_EXECUTED=false
FAILURE_MESSAGE=""

# Record the error so it can be repeated after any cleanup output, then exit.
fail() {
  FAILURE_MESSAGE="$*"
  die "$*"
}

# --- Placeholder cleanup -----------------------------------------------------
# Creating a CREATE change set makes an empty stack in REVIEW_IN_PROGRESS.
# If the change set is never executed (declined, error, Ctrl+C) that empty
# stack is left behind and blocks the next run. Remove it, but only when every
# check below confirms it is the unexecuted placeholder from this run.
# Returns non-zero if a placeholder may still exist.
remove_unexecuted_placeholder() {
  # Check 1: this run created a change set and did not execute it.
  [[ -n "${CREATED_STACK_ID}" && "${CHANGE_SET_EXECUTED}" == false ]] || return 0

  info "Checking for an unexecuted placeholder stack"
  local manual="aws cloudformation delete-stack --region ${AWS_REGION} --stack-name ${CREATED_STACK_ID}"
  local details name status exec_status resource_count output

  # Look the stack up by the exact ID this run created, never by a pattern.
  if ! details="$(cfn describe-stacks --stack-name "${CREATED_STACK_ID}" \
                    --query 'Stacks[0].[StackName,StackStatus]' --output text 2>&1)"; then
    warn "Could not check the placeholder stack: ${details}"
    warn "Check it in the console and, if it is REVIEW_IN_PROGRESS, remove it with: ${manual}"
    return 1
  fi
  read -r name status <<<"${details}"

  # Check 2: it is the configured stack.
  if [[ "${name}" != "${STACK_NAME}" ]]; then
    warn "Stack name '${name}' does not match configured '${STACK_NAME}'. Not deleting it."
    return 1
  fi

  # Check 3: it is still only a placeholder.
  if [[ "${status}" != "REVIEW_IN_PROGRESS" ]]; then
    echo "  Stack status is ${status}, so it is not an unexecuted placeholder. Leaving it unchanged."
    return 0
  fi

  # Check 4: the change set was never executed.
  if ! exec_status="$(cfn describe-change-set --change-set-name "${CHANGE_SET_ID}" \
                        --query 'ExecutionStatus' --output text 2>&1)"; then
    warn "Could not check the change set: ${exec_status}"
    warn "Not deleting automatically. If safe, remove it with: ${manual}"
    return 1
  fi
  case "${exec_status}" in
    EXECUTE_IN_PROGRESS|EXECUTE_COMPLETE|EXECUTE_FAILED)
      warn "Change set execution status is ${exec_status}. Not deleting the stack."
      return 1 ;;
  esac

  # Check 5: the stack holds no resources.
  if ! resource_count="$(cfn describe-stack-resources --stack-name "${CREATED_STACK_ID}" \
                           --query 'length(StackResources)' --output text 2>&1)"; then
    warn "Could not list stack resources: ${resource_count}"
    warn "Not deleting automatically. If safe, remove it with: ${manual}"
    return 1
  fi
  if [[ "${resource_count}" != "0" ]]; then
    warn "Stack has ${resource_count} resource(s). Not deleting it."
    return 1
  fi

  echo "  Confirmed: '${STACK_NAME}' is an empty, unexecuted placeholder. Removing it."
  if ! output="$(cfn delete-stack --stack-name "${CREATED_STACK_ID}" 2>&1)"; then
    warn "delete-stack failed: ${output}"
    warn "Remove it manually with: ${manual}"
    return 1
  fi
  if ! output="$(cfn wait stack-delete-complete --stack-name "${CREATED_STACK_ID}" 2>&1)"; then
    warn "Placeholder deletion did not complete: ${output}"
    warn "Check its status with: aws cloudformation describe-stacks --region ${AWS_REGION} --stack-name ${CREATED_STACK_ID}"
    return 1
  fi
  echo "  Placeholder stack removed. No resources were created."
}

# Runs on every exit: clean up any placeholder, repeat the original error last
# so it is not lost among cleanup messages, and keep the original exit code.
on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if ! remove_unexecuted_placeholder && [[ "${rc}" -eq 0 ]]; then
    rc=1
  fi
  if [[ -n "${FAILURE_MESSAGE}" && -n "${CREATED_STACK_ID}" && "${CHANGE_SET_EXECUTED}" == false ]]; then
    printf '\nOriginal error: %s\n' "${FAILURE_MESSAGE}" >&2
  fi
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- 1. Pre-flight checks ----------------------------------------------------
require_cmd aws
[[ -f "${TEMPLATE_FILE}" ]] || fail "Template not found: ${TEMPLATE_FILE}"

info "Checking AWS identity"
if ! ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>&1)"; then
  fail "Unable to call AWS. Check that your AWS CLI credentials are configured.
${ACCOUNT_ID}"
fi

cat <<EOF
  Account     : ${ACCOUNT_ID}
  Region      : ${AWS_REGION}
  Stack       : ${STACK_NAME}
  Template    : ${TEMPLATE_FILE#"${REPO_ROOT}/"}
  Parameters  : ProjectName=${PROJECT_NAME}, Environment=${ENVIRONMENT}, Owner=${OWNER}
EOF

# --- 2. Stack must not exist yet ---------------------------------------------
info "Checking that stack '${STACK_NAME}' does not already exist"
STATUS="$(stack_status)"
case "${STATUS}" in
  DOES_NOT_EXIST)
    echo "  OK - stack does not exist." ;;
  REVIEW_IN_PROGRESS)
    fail "Stack '${STACK_NAME}' is in REVIEW_IN_PROGRESS from an earlier unexecuted change set.
This script only removes placeholders it created in the same run. Remove it
(it contains no resources) and re-run:
  aws cloudformation delete-stack --region ${AWS_REGION} --stack-name ${STACK_NAME}" ;;
  *)
    fail "Stack '${STACK_NAME}' already exists with status ${STATUS}. This script only creates new stacks." ;;
esac

# --- 3. Create the change set ------------------------------------------------
info "Creating change set '${CHANGE_SET_NAME}'"
if ! CREATE_OUTPUT="$(cfn create-change-set \
       --stack-name "${STACK_NAME}" \
       --change-set-name "${CHANGE_SET_NAME}" \
       --change-set-type CREATE \
       --template-body "file://${TEMPLATE_FILE}" \
       --parameters "${STACK_PARAMETERS[@]}" \
       --description "Initial creation of ${STACK_NAME}" \
       --query '[Id,StackId]' --output text 2>&1)"; then
  fail "create-change-set failed:
${CREATE_OUTPUT}"
fi
read -r CHANGE_SET_ID CREATED_STACK_ID <<<"${CREATE_OUTPUT}"
if [[ "${CHANGE_SET_ID}" != arn:aws*:changeSet/* || "${CREATED_STACK_ID}" != arn:aws*:stack/* ]]; then
  CHANGE_SET_ID="" CREATED_STACK_ID=""
  fail "Unexpected create-change-set response, so automatic cleanup is disabled:
${CREATE_OUTPUT}
Check whether '${STACK_NAME}' exists in REVIEW_IN_PROGRESS and, if so, remove it with:
  aws cloudformation delete-stack --region ${AWS_REGION} --stack-name ${STACK_NAME}"
fi
echo "  Change set : ${CHANGE_SET_ID}"

echo "  Waiting for the change set to be ready..."
if ! WAIT_OUTPUT="$(cfn wait change-set-create-complete \
                      --change-set-name "${CHANGE_SET_ID}" 2>&1)"; then
  if ! REASON="$(cfn describe-change-set --change-set-name "${CHANGE_SET_ID}" \
                   --query 'StatusReason' --output text 2>&1)"; then
    REASON="(could not describe change set) ${REASON}"
  fi
  fail "Change set creation failed.
  CloudFormation : ${REASON}
  Waiter         : ${WAIT_OUTPUT}"
fi

info "Proposed changes"
cfn describe-change-set --change-set-name "${CHANGE_SET_ID}" \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' \
  --output table

# --- 4. Confirm ----------------------------------------------------------------
if ! confirm "Execute change set '${CHANGE_SET_NAME}' and create these resources?"; then
  echo "Cancelled. The change set will not be executed."
  exit 0
fi

# --- 5. Execute and wait -----------------------------------------------------
info "Executing change set"
if ! EXEC_OUTPUT="$(cfn execute-change-set --change-set-name "${CHANGE_SET_ID}" 2>&1)"; then
  fail "execute-change-set failed:
${EXEC_OUTPUT}"
fi
CHANGE_SET_EXECUTED=true

echo "  Waiting for stack creation to complete (usually under a minute)..."
if ! WAIT_OUTPUT="$(cfn wait stack-create-complete --stack-name "${STACK_NAME}" 2>&1)"; then
  warn "Stack creation did not complete. Status: $(stack_status)"
  info "Recent stack events (look for CREATE_FAILED and its reason)"
  show_recent_events 20 || true
  fail "Deployment failed: ${WAIT_OUTPUT}
Fix the cause, delete the stack, then re-run this script:
  aws cloudformation delete-stack --region ${AWS_REGION} --stack-name ${STACK_NAME}"
fi

info "Stack created: $(stack_status)"

info "Stack outputs"
show_outputs

info "Recent stack events"
show_recent_events 15

info "Done."
