#!/bin/bash

# Function to get parameter from SSM
get_ssm_parameter() {
    aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

# Set environment variables from SSM
export S3_BUCKET=$(get_ssm_parameter "/myapp/S3_BUCKET")
export CONNECTIONS_TABLE=$(get_ssm_parameter "/myapp/CONNECTIONS_TABLE")
export SECRET_KEY=$(get_ssm_parameter "/myapp/SECRET_KEY")
export AWS_REGION=$(get_ssm_parameter "/myapp/AWS_REGION")

# Additional environment variables
export FLASK_APP=app.py
export FLASK_ENV=production

# Install dependencies (uncomment if needed)
# pip install -r requirements.txt

# Run the Flask application with Gunicorn
gunicorn --bind 0.0.0.0:5000 app:app
