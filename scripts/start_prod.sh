#!/bin/bash

# Set the working directory
cd /opt/app

# Activate virtual environment
source /opt/app/venv/bin/activate

# Function to get parameter from SSM
get_ssm_parameter() {
    aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

# Set environment variables from SSM
export S3_BUCKET=$(get_ssm_parameter "/myapp/S3_BUCKET")
export CONNECTIONS_TABLE=$(get_ssm_parameter "/myapp/CONNECTIONS_TABLE")
export SECRET_KEY=$(get_ssm_parameter "/myapp/SECRET_KEY")
export GOOGLE_API_KEY=$(get_ssm_parameter "/myapp/GOOGLE_API_KEY")
export WSS_URL=$(get_ssm_parameter "/myapp/WSS_URL")
export WEBSOCKET_LAMBDA_NAME=$(get_ssm_parameter "/myapp/WEBSOCKET_LAMBDA_NAME")
export AWS_DEFAULT_REGION=$(get_ssm_parameter "/myapp/AWS_DEFAULT_REGION")

# Print the values for debugging (remove in production)
echo "S3_BUCKET: $S3_BUCKET"
echo "CONNECTIONS_TABLE: $CONNECTIONS_TABLE"
echo "SECRET_KEY: ${SECRET_KEY:0:5}..." # Only print first 5 characters
echo "GOOGLE_API_KEY: ${GOOGLE_API_KEY:0:5}..." # Only print first 5 characters
echo "WSS_URL: $WSS_URL"
echo "WEBSOCKET_LAMBDA_NAME: $WEBSOCKET_LAMBDA_NAME"
echo "AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
# Additional environment variables
export FLASK_APP=app.py
export FLASK_ENV=production

# Install requirements
pip install -r requirements.txt

# Run the Flask application with Gunicorn
exec gunicorn --bind 0.0.0.0:5000 app:app