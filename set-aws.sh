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

# Create S3 bucket
aws --endpoint-url=$ENDPOINT_URL s3 mb s3://$S3_BUCKET > /dev/null 2>&1
log_result "Creating S3 bucket" "Failed to create S3 bucket $S3_BUCKET"

# Create SQS queue
aws --endpoint-url=$ENDPOINT_URL sqs create-queue --queue-name $SQS_QUEUE_NAME > /dev/null 2>&1
log_result "Creating SQS queue" "Failed to create SQS queue $SQS_QUEUE_NAME"

# Create DynamoDB table
aws --endpoint-url=$ENDPOINT_URL dynamodb create-table \
    --table-name $DYNAMODB_TABLE_NAME \
    --attribute-definitions \
        AttributeName=connectionId,AttributeType=S \
        AttributeName=fileName,AttributeType=S \
    --key-schema \
        AttributeName=connectionId,KeyType=HASH \
        AttributeName=fileName,KeyType=RANGE \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 > /dev/null 2>&1
log_result "Creating DynamoDB table" "Failed to create DynamoDB table $DYNAMODB_TABLE_NAME"

# Create a Global Secondary Index (GSI) on fileName
aws --endpoint-url=$ENDPOINT_URL dynamodb update-table \
    --table-name $DYNAMODB_TABLE_NAME \
    --attribute-definitions AttributeName=fileName,AttributeType=S \
    --global-secondary-index-updates \
        "[{\"Create\":{\"IndexName\": \"FileNameIndex\",\"KeySchema\":[{\"AttributeName\":\"fileName\",\"KeyType\":\"HASH\"}], \
        \"Projection\":{\"ProjectionType\":\"ALL\"},\"ProvisionedThroughput\":{\"ReadCapacityUnits\":5,\"WriteCapacityUnits\":5}}}]" > /dev/null 2>&1
log_result "Creating GSI on DynamoDB table" "Failed to create GSI on DynamoDB table $DYNAMODB_TABLE_NAME"

# Add SSM parameters
add_ssm_parameter() {
    local name=$1
    local value=$2
    aws --endpoint-url=$ENDPOINT_URL ssm put-parameter --name "$name" --value "$value" --type String --overwrite > /dev/null 2>&1
    log_result "Adding SSM parameter: $name" "Failed to add SSM parameter: $name"
}

add_ssm_parameter "/myapp/S3_BUCKET" "$S3_BUCKET"
add_ssm_parameter "/myapp/SQS_QUEUE_URL" "$ENDPOINT_URL/000000000000/$SQS_QUEUE_NAME"
add_ssm_parameter "/myapp/CONNECTIONS_TABLE" "$DYNAMODB_TABLE_NAME"
add_ssm_parameter "/myapp/WEBSOCKET_API" "$WEBSOCKET_API_ID"
add_ssm_parameter "/myapp/GOOGLE_API_KEY" "$GOOGLE_API_KEY"
add_ssm_parameter "/myapp/SECRET_KEY" "$SECRET_KEY"
add_ssm_parameter "/myapp/AWS_DEFAULT_REGION" "$AWS_DEFAULT_REGION"

# Create Lambda function
LAMBDA_FUNCTION_NAME="ProcessImageLambda"
LAMBDA_ROLE_NAME="ProcessImageLambdaRole"

# Create IAM role for Lambda
aws --endpoint-url=$ENDPOINT_URL iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{ "Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}' > /dev/null 2>&1
log_result "Creating IAM role for Lambda" "Failed to create IAM role for Lambda"

# Attach basic execution policy to the role
aws --endpoint-url=$ENDPOINT_URL iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole > /dev/null 2>&1
log_result "Attaching basic execution policy to Lambda role" "Failed to attach policy to Lambda role"

# Create Lambda function
aws --endpoint-url=$ENDPOINT_URL lambda create-function \
    --function-name $LAMBDA_FUNCTION_NAME \
    --runtime python3.9 \
    --role arn:aws:iam::000000000000:role/$LAMBDA_ROLE_NAME \
    --handler processImageLambda.handler \
    --zip-file fileb://<(zip -j - processImageLambda.py) \
    --environment "Variables={ALB_DNS=$ALB_DNS,SECRET_KEY=$SECRET_KEY}" > /dev/null 2>&1
log_result "Creating Lambda function" "Failed to create Lambda function"

# Add S3 bucket notification to trigger Lambda
aws --endpoint-url=$ENDPOINT_URL s3api put-bucket-notification-configuration \
    --bucket $S3_BUCKET \
    --notification-configuration '{
        "LambdaFunctionConfigurations": [{
            "LambdaFunctionArn": "arn:aws:lambda:'$AWS_DEFAULT_REGION':000000000000:function:'$LAMBDA_FUNCTION_NAME'",
            "Events": ["s3:ObjectCreated:*"]
        }]
    }' > /dev/null 2>&1
log_result "Adding S3 bucket notification" "Failed to add S3 bucket notification"

# Add permission for S3 to invoke Lambda
aws --endpoint-url=$ENDPOINT_URL lambda add-permission \
    --function-name $LAMBDA_FUNCTION_NAME \
    --statement-id S3InvokeLambda \
    --action "lambda:InvokeFunction" \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::$S3_BUCKET > /dev/null 2>&1
log_result "Adding permission for S3 to invoke Lambda" "Failed to add permission for S3 to invoke Lambda"

echo "✅ AWS resources setup complete"