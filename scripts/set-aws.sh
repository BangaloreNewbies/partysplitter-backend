# Function to set up S3 bucket
setup_s3_bucket() {
    log_message "Setting up S3 bucket"
    if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
        log_message "S3 bucket $S3_BUCKET already exists"
    else
        if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager s3 mb "s3://$S3_BUCKET"; then
            log_result "Creating S3 bucket"

            run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager s3api put-bucket-cors --bucket "$S3_BUCKET" --cors-configuration '{
                "CORSRules": [
                    {
                        "AllowedOrigins": ["*"],
                        "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
                        "AllowedHeaders": ["*"],
                        "ExposeHeaders": ["ETag"]
                    }
                ]
            }'
            log_result "Setting CORS configuration for S3 bucket"
        else
            log_error "Failed to create S3 bucket $S3_BUCKET"
        fi
    fi
}

# Function to set up DynamoDB table
setup_dynamodb_table() {
    log_message "Setting up DynamoDB table"
    if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" &>/dev/null; then
        log_message "DynamoDB table $DYNAMODB_TABLE_NAME already exists"
    else
        log_message "DynamoDB table $DYNAMODB_TABLE_NAME does not exist. Creating..."
        if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager dynamodb create-table \
            --table-name "$DYNAMODB_TABLE_NAME" \
            --attribute-definitions \
                AttributeName=connectionId,AttributeType=S \
                AttributeName=fileName,AttributeType=S \
            --key-schema \
                AttributeName=connectionId,KeyType=HASH \
                AttributeName=fileName,KeyType=RANGE \
            --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5; then

            log_result "Created DynamoDB table $DYNAMODB_TABLE_NAME"

            # Wait for the table to be active
            log_message "Waiting for DynamoDB table to become active..."
            aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager dynamodb wait table-exists --table-name "$DYNAMODB_TABLE_NAME"

            run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager dynamodb update-table \
                --table-name "$DYNAMODB_TABLE_NAME" \
                --attribute-definitions AttributeName=fileName,AttributeType=S \
                --global-secondary-index-updates \
                    "[{\"Create\":{\"IndexName\": \"FileNameIndex\",\"KeySchema\":[{\"AttributeName\":\"fileName\",\"KeyType\":\"HASH\"}], \
                    \"Projection\":{\"ProjectionType\":\"ALL\"},\"ProvisionedThroughput\":{\"ReadCapacityUnits\":5,\"WriteCapacityUnits\":5}}}]"
            log_result "Created GSI on DynamoDB table $DYNAMODB_TABLE_NAME"
        else
            log_error "Failed to create DynamoDB table $DYNAMODB_TABLE_NAME"
        fi
    fi
}

# Generic function to set up a Lambda function
setup_lambda_function() {
    local lambda_name=$1
    local role_name=$2
    local handler=$3
    local zip_file=$4
    local environment_vars=$5

    log_message "Setting up Lambda function: $lambda_name"
    local policy_arn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    local role_arn=$(ensure_role_exists "$role_name" "$policy_arn" | xargs)

    # Emit error if role ARN is empty or invalid
    if [ -z "$role_arn" ] || [ "$role_arn" = "None" ]; then
        log_error "Failed to create or retrieve role $role_name"
        return 1
    fi

    log_message "Using role ARN: $role_arn"

    # Create zip file for Lambda function
    if ! zip -j "$zip_file" "$ROOT_DIR/lambdas/$lambda_name.py"; then
        log_error "Failed to create zip file for Lambda function"
        return 1
    fi

    local existing_hash=$(get_local_lambda_hash "$lambda_name")
    local new_hash=$(openssl dgst -sha256 -binary "$zip_file" | openssl enc -base64)

    # Check if Lambda function exists
    if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda get-function --function-name "$lambda_name" &>/dev/null; then
        log_message "Lambda function $lambda_name already exists. Updating..."

        # Update function code
        if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda update-function-code \
            --function-name "$lambda_name" \
            --zip-file fileb://"$zip_file"; then
            log_result "Updated Lambda function code: $lambda_name"
        else
            log_error "Failed to update Lambda function code: $lambda_name"
            rm "$zip_file"
            return 1
        fi

        # Update function configuration
        if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda update-function-configuration \
            --function-name "$lambda_name" \
            --handler "$handler" \
            --environment "$environment_vars"; then
            log_result "Updated Lambda function configuration: $lambda_name"
        else
            log_error "Failed to update Lambda function configuration: $lambda_name"
            rm "$zip_file"
            return 1
        fi
    else
        log_message "Creating Lambda function: $lambda_name"

        # Check if environment_vars is empty and set a default if it is
        if [ -z "$environment_vars" ] || [ "$environment_vars" = "{}" ]; then
            environment_vars="Variables={}"
        fi

        # Attempt to create the Lambda function
        if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda create-function \
            --function-name "$lambda_name" \
            --runtime python3.9 \
            --role "$role_arn" \
            --handler "$handler" \
            --zip-file fileb://"$zip_file" \
            --environment "$environment_vars"; then
            log_result "Created Lambda function: $lambda_name"
        else
            log_error "Failed to create Lambda function: $lambda_name"
            rm "$zip_file"
            return 1
        fi
    fi

    save_local_lambda_hash "$lambda_name" "$new_hash"
    rm "$zip_file"
    log_message "Lambda function setup complete: $lambda_name"
}

# Function to set up Process Image Lambda
setup_process_image_lambda() {
    local lambda_name="ProcessImageLambda"
    local role_name="ProcessImageLambdaRole"
    local handler="ProcessImageLambda.handler"
    local zip_file="process_image_lambda.zip"
    local environment_vars="Variables={HOST_SERVICE_URL=http://$HOST_IP:5000,SECRET_KEY=$SECRET_KEY}"

    setup_lambda_function "$lambda_name" "$role_name" "$handler" "$zip_file" "$environment_vars"
}

# Function to set up S3 notification for ProcessImageLambda
setup_s3_notification() {
    log_message "Setting up S3 notification for ProcessImageLambda"

    # Get the ARN of the ProcessImageLambda
    local lambda_arn=$(run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda get-function --function-name "ProcessImageLambda" --query 'Configuration.FunctionArn' --output text)

    if [ -z "$lambda_arn" ]; then
        log_error "Failed to get ARN for ProcessImageLambda"
        return 1
    fi

    # Add permission to S3 to invoke the Lambda function
    log_message "Adding permission for S3 to invoke ProcessImageLambda"
    if ! run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager lambda add-permission \
        --function-name "ProcessImageLambda" \
        --statement-id "S3InvokeFunction" \
        --action "lambda:InvokeFunction" \
        --principal s3.amazonaws.com \
        --source-arn "arn:aws:s3:::$S3_BUCKET"; then
        log_error "Failed to add permission for S3 to invoke ProcessImageLambda"
        return 1
    fi
    log_result "Added permission for S3 to invoke ProcessImageLambda"

    # Create a notification configuration
    local notification_config=$(cat <<EOF
{
    "LambdaFunctionConfigurations": [
        {
            "LambdaFunctionArn": "$lambda_arn",
            "Events": ["s3:ObjectCreated:Put"]
        }
    ]
}
EOF
)

    # Apply the notification configuration to the S3 bucket
    log_message "Applying S3 notification configuration"
    if run_aws_command aws --endpoint-url="$ENDPOINT_URL" --no-cli-pager s3api put-bucket-notification-configuration \
        --bucket "$S3_BUCKET" \
        --notification-configuration "$notification_config"; then
        log_result "S3 notification set up successfully"
    else
        log_error "Failed to set up S3 notification"
        return 1
    fi
}

# Main setup function
setup_aws() {
    log_message "Setting up AWS resources"
    log_message "ENDPOINT_URL is set to: $ENDPOINT_URL"
    log_message "Checking LocalStack accessibility..."
    if curl -s "$ENDPOINT_URL" > /dev/null; then
        log_message "LocalStack is accessible"
    else
        log_error "Cannot reach LocalStack at $ENDPOINT_URL"
        return 1
    fi

    export AWS_DEFAULT_OUTPUT=text
    HOST_IP=$(docker network inspect localstack_network | grep -oP '(?<="Gateway": ")[^"]*')
    log_message "Host IP on bridge network: $HOST_IP"

    setup_s3_bucket
    setup_dynamodb_table

    add_ssm_parameter "/myapp/S3_BUCKET" "$S3_BUCKET"
    add_ssm_parameter "/myapp/CONNECTIONS_TABLE" "$DYNAMODB_TABLE_NAME"
    add_ssm_parameter "/myapp/GOOGLE_API_KEY" "$GOOGLE_API_KEY"
    add_ssm_parameter "/myapp/SECRET_KEY" "$SECRET_KEY"
    add_ssm_parameter "/myapp/AWS_DEFAULT_REGION" "$AWS_DEFAULT_REGION"
    add_ssm_parameter "/myapp/ENVIRONMENT" "$ENVIRONMENT"
    add_ssm_parameter "/myapp/WSS_URL" "$WSS_URL"
    add_ssm_parameter "/myapp/WEBSOCKET_LAMBDA_NAME" "$WEBSOCKET_LAMBDA_NAME"

    setup_process_image_lambda
    setup_s3_notification

    log_message "AWS resources setup complete"
    log_message "Full setup log available in $LOG_FILE"
    log_message "Error log available in $ERROR_LOG_FILE"
}