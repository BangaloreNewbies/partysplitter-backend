#!/bin/bash

# Define the root directory
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source the utils.sh file
source "$ROOT_DIR/scripts/utils.sh"
source "$ROOT_DIR/scripts/set-aws.sh"

# Load environment variables from .env.local file
if [ -f "$ROOT_DIR/.env.local" ]; then
    set -a
    source "$ROOT_DIR/.env.local"
    set +a
    log_message "Loaded .env.local"
else
    log_error ".env.local file not found"
    exit 1
fi

# Check if docker-compose.yml has been modified
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
COMPOSE_HASH_FILE="$TMP_DIR/.compose_hash"

if [ -f "$COMPOSE_HASH_FILE" ]; then
    OLD_HASH=$(cat "$COMPOSE_HASH_FILE")
else
    OLD_HASH=""
fi

NEW_HASH=$(md5sum "$COMPOSE_FILE" | awk '{print $1}')

if [ "$OLD_HASH" != "$NEW_HASH" ]; then
    log_message "docker-compose.yml has been modified. Restarting containers..."
    docker compose down
    docker compose build --no-cache
    docker compose up -d
    echo "$NEW_HASH" > "$COMPOSE_HASH_FILE"
    log_result "Starting LocalStack"
else
    log_message "No changes in docker-compose.yml. Using existing containers."
fi

# Wait for LocalStack to be ready
log_message "Waiting for LocalStack to be ready..."
while ! curl -s "$ENDPOINT_URL" > /dev/null; do
    sleep 1
done
log_message "LocalStack is ready."

# Check if set-aws.sh has been modified
SET_AWS_FILE="$ROOT_DIR/scripts/set-aws.sh"
SET_AWS_HASH_FILE="$TMP_DIR/.set_aws_hash"

if [ -f "$SET_AWS_HASH_FILE" ]; then
    OLD_SET_AWS_HASH=$(cat "$SET_AWS_HASH_FILE")
else
    OLD_SET_AWS_HASH=""
fi

NEW_SET_AWS_HASH=$(md5sum "$SET_AWS_FILE" | awk '{print $1}')

if [ "$OLD_SET_AWS_HASH" != "$NEW_SET_AWS_HASH" ]; then
    log_message "set-aws.sh has been modified. Setting up AWS resources..."
    # Set up AWS resources using values from .env.local
    setup_aws
    log_result "Setting up AWS resources"
    echo "$NEW_SET_AWS_HASH" > "$SET_AWS_HASH_FILE"
else
    log_message "No changes in set-aws.sh. Skipping AWS resource setup."
fi

# Set environment variables for LocalStack
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-south-1

# Function to get parameter from SSM
get_ssm_parameter() {
    aws --endpoint-url="$ENDPOINT_URL" ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

# Set environment variables from SSMa
export S3_BUCKET=$(get_ssm_parameter "/myapp/S3_BUCKET")
export CONNECTIONS_TABLE=$(get_ssm_parameter "/myapp/CONNECTIONS_TABLE")
export GOOGLE_API_KEY=$(get_ssm_parameter "/myapp/GOOGLE_API_KEY")
export SECRET_KEY=$(get_ssm_parameter "/myapp/SECRET_KEY")
export AWS_DEFAULT_REGION=$(get_ssm_parameter "/myapp/AWS_DEFAULT_REGION")
export WEBSOCKET_LAMBDA_NAME=$(get_ssm_parameter "/myapp/WEBSOCKET_LAMBDA_NAME")
export WSS_URL=$(get_ssm_parameter "/myapp/WSS_URL")

log_result "Setting environment variables from SSM"

# Set Flask environment variables
export FLASK_APP=app.py
export FLASK_ENV=development

# Install dependencies
pip install -r requirements.txt
log_result "Installing dependencies"

# Run the Flask development server
log_message "Starting Flask development server..."
flask run --host=0.0.0.0 --port=5000