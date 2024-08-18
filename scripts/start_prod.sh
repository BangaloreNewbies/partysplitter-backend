#!/bin/bash

# Function to get parameter from SSM
get_ssm_parameter() {
    aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

# Set environment variables from SSM
export S3_BUCKET=$(get_ssm_parameter "/myapp/S3_BUCKET")
export CONNECTIONS_TABLE=$(get_ssm_parameter "/myapp/CONNECTIONS_TABLE")
export SECRET_KEY=$(get_ssm_parameter "/myapp/SECRET_KEY")
export GOOGLE_API_KEY=$(get_ssm_parameter "/myapp/GOOGLE_API_KEY")
export AWS_DEFAULT_REGION=$(get_ssm_parameter "/myapp/AWS_DEFAULT_REGION")
export WSS_URL=$(get_ssm_parameter "/myapp/WSS_URL")
export WEBSOCKET_LAMBDA_NAME=$(get_ssm_parameter "/myapp/WEBSOCKET_LAMBDA_NAME")
export AWS_ACCESS_KEY_ID=$(get_ssm_parameter "/myapp/AWS_ACCESS_KEY_ID")
export AWS_SECRET_ACCESS_KEY=$(get_ssm_parameter "/myapp/AWS_SECRET_ACCESS_KEY")


# Additional environment variables
export FLASK_APP=app.py
export FLASK_ENV=production

pip install -r requirements.txt

# Run the Flask application with Gunicorn
gunicorn --bind 0.0.0.0:5000 app:app
