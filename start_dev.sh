#!/bin/bash

# Function to log success or failure
log_result() {
    if [ $? -eq 0 ]; then
        echo "✅ $1 successful"
    else
        echo "❌ $1 failed"
        echo "Error details: $2"
        exit 1
    fi
}

# Load environment variables from .env.local file
if [ -f .env.local ]; then
    export $(cat .env.local | xargs)
    log_result "Loading .env.local" "File not found or permission denied"
else
    echo "❌ .env.local file not found"
    exit 1
fi

# Start LocalStack
docker compose down
docker compose build --no-cache
docker compose up -d
log_result "Starting LocalStack" "Docker Compose failed to start LocalStack"

# Wait for LocalStack to be ready
echo "Waiting for LocalStack to be ready..."
sleep 15

# Set environment variables for LocalStack
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-south-1

# Export the environment variables
export S3_BUCKET
export SQS_QUEUE_NAME
export DYNAMODB_TABLE_NAME
export WEBSOCKET_API_ID
export GOOGLE_API_KEY
export SECRET_KEY
export AWS_DEFAULT_REGION
export ENDPOINT_URL

# Set up AWS resources using values from .env.local
./set-aws.sh
log_result "Setting up AWS resources" "Check set-aws.sh for detailed error messages"

# Function to get parameter from SSM
get_ssm_parameter() {
    aws --endpoint-url=$ENDPOINT_URL ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

# Set environment variables from SSM
export S3_BUCKET=$(get_ssm_parameter "/myapp/S3_BUCKET")
export SQS_QUEUE_URL=$(get_ssm_parameter "/myapp/SQS_QUEUE_URL")
export CONNECTIONS_TABLE=$(get_ssm_parameter "/myapp/CONNECTIONS_TABLE")
export WEBSOCKET_API=$(get_ssm_parameter "/myapp/WEBSOCKET_API")
export GOOGLE_API_KEY=$(get_ssm_parameter "/myapp/GOOGLE_API_KEY")
export SECRET_KEY=$(get_ssm_parameter "/myapp/SECRET_KEY")
export AWS_DEFAULT_REGION=$(get_ssm_parameter "/myapp/AWS_DEFAULT_REGION")
log_result "Setting environment variables from SSM" "Failed to retrieve one or more SSM parameters"

# Set Flask environment variables
export FLASK_APP=app.py
export FLASK_ENV=development

# Install dependencies (uncomment if needed)
pip install -r requirements.txt
log_result "Installing dependencies" "pip install failed"

# Run the Flask development server
echo "Starting Flask development server..."
flask run --host=0.0.0.0 --port=5000