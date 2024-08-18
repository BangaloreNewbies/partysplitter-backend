#!/bin/bash

# Ensure ROOT_DIR is set
if [ -z "$ROOT_DIR" ]; then
    echo "ERROR: ROOT_DIR is not set. Please set it before running this script."
    exit 1
fi

TMP_DIR="$ROOT_DIR/.tmp"
LOG_DIR="$ROOT_DIR/log"

mkdir -p "$LOG_DIR"
mkdir -p "$TMP_DIR"

LOG_FILE="$LOG_DIR/set-local.log"
ERROR_LOG_FILE="$LOG_DIR/set-local.error.log"

# Logging functions
log_message() {
    local message=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message" | tee -a "$ERROR_LOG_FILE" >&2
}

log_result() {
    local result=$1
    if [ $? -eq 0 ]; then
        log_message "$result successful"
    else
        log_error "$result failed"
    fi
}

# Function to run AWS commands with error logging
run_aws_command() {
    local output
    output=$( "$@" 2>&1 )
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to execute: $*"
        log_error "Error details: $output"
        return $exit_code
    fi
    echo "$output"
}

# Function to add or update SSM parameter
add_ssm_parameter() {
    if ! run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager ssm get-parameter --name "$1" &>/dev/null; then
        run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager ssm put-parameter --name "$1" --value "$2" --type String --overwrite
        log_result "Adding SSM parameter: $1"
    else
        log_message "SSM parameter $1 already exists"
    fi
}

# Function to ensure the IAM role exists, attach the policy, and return its ARN
ensure_role_exists() {
    local role_name=$1
    local policy_arn=$2
    local role_arn

    # Check if the role already exists
    role_arn=$(run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager iam get-role --role-name "$role_name" --query 'Role.Arn' --output text 2>/dev/null)

    if [ -z "$role_arn" ] || [ "$role_arn" = "None" ]; then
        # Create the role and capture the ARN from the output
        role_arn=$(run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{ "Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}' \
            --query 'Role.Arn' --output text)
    fi

    # Attach the policy to the role
    run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn"

    # Trim any whitespace from the role_arn
    role_arn=$(echo "$role_arn" | tr -d '[:space:]')
    echo "$role_arn"
}

get_local_lambda_hash() {
    local lambda_name=$1
    local hash_file="$TMP_DIR/.${lambda_name}_hash"
    if [ -f "$hash_file" ]; then
        cat "$hash_file"
    else
        echo ""
    fi
}

save_local_lambda_hash() {
    local lambda_name=$1
    local new_hash=$2
    local hash_file="$TMP_DIR/.${lambda_name}_hash"
    echo "$new_hash" > "$hash_file"
}
