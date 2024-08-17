from flask import Flask, request, jsonify
from functools import wraps
import boto3
import os
import json
import uuid
import base64
import google.generativeai as genai
from botocore.exceptions import ClientError

def check_environment_variables():
    required_vars = [
        "S3_BUCKET", "SQS_QUEUE_URL", "CONNECTIONS_TABLE",
        "WEBSOCKET_API", "GOOGLE_API_KEY", "SECRET_KEY",
        "AWS_DEFAULT_REGION"
    ]
    missing_vars = [var for var in required_vars if not os.getenv(var)]
    if missing_vars:
        raise EnvironmentError(f"Missing required environment variables: {', '.join(missing_vars)}")

# Run the check immediately
check_environment_variables()

# Now it's safe to access these variables
S3_BUCKET = os.environ['S3_BUCKET']
SQS_QUEUE_URL = os.environ['SQS_QUEUE_URL']
CONNECTIONS_TABLE = os.environ['CONNECTIONS_TABLE']
WEBSOCKET_API = os.environ['WEBSOCKET_API']
GOOGLE_API_KEY = os.environ['GOOGLE_API_KEY']
SECRET_KEY = os.environ['SECRET_KEY']

app = Flask(__name__)

# Determine the endpoint URL and AWS region based on the environment
ENDPOINT_URL = os.environ.get('ENDPOINT_URL')
AWS_REGION = os.environ.get('AWS_DEFAULT_REGION')

# Function to get boto3 client args
def get_boto3_client_args():
    args = {'region_name': AWS_REGION}
    if ENDPOINT_URL:
        args['endpoint_url'] = ENDPOINT_URL
    return args

# Create AWS clients with the appropriate endpoint URL and region
s3_client = boto3.client('s3', **get_boto3_client_args())
sqs_client = boto3.client('sqs', **get_boto3_client_args())
dynamodb = boto3.resource('dynamodb', **get_boto3_client_args())

genai.configure(api_key=GOOGLE_API_KEY)

@app.route('/health')
def health_check():
   return 'OK', 200

@app.route('/api/bill_url', methods=['GET'])
def get_presigned_url():
    file_name = f"upload_{str(uuid.uuid4())}.jpg"
    presigned_url = s3_client.generate_presigned_url(
        'put_object',
        Params={'Bucket': S3_BUCKET, 'Key': file_name},
        ExpiresIn=3600
    )

    # Generate a temporary ID for the file
    temp_id = str(uuid.uuid4())

    # Store the file name with a temporary ID
    store_file_info(temp_id, file_name)

    return jsonify({
        'uploadUrl': presigned_url,
        'fileName': file_name,
        'tempId': temp_id
    }), 200

def store_file_info(temp_id, file_name):
    try:
        connections_table = dynamodb.Table(CONNECTIONS_TABLE)
        connections_table.put_item(
            Item={
                'connectionId': temp_id,  # Use temp_id as the connectionId
                'fileName': file_name,
                'status': 'pending'  # Indicates that no WebSocket connection is associated yet
            }
        )
    except ClientError as e:
        print(f"Error storing file info: {str(e)}")
        raise

def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')
        if not token:
            return jsonify({'message': 'Token is missing!'}), 401
        if token != f"Bearer {SECRET_KEY}":
            return jsonify({'message': 'Invalid token!'}), 401
        return f(*args, **kwargs)
    return decorated

@app.route('/api/process_image', methods=['POST'])
@token_required
def process_image():
    data = request.json
    file_name = data['fileName']

    try:
        # Download the image from S3
        response = s3_client.get_object(Bucket=S3_BUCKET, Key=file_name)
        image_content = response['Body'].read()

        # Process the image with Gemini 1.5 Flash
        gemini_response = process_with_gemini(image_content)

        # Prepare processing results
        processing_results = {
            'fileName': file_name,
            'gemini_analysis': gemini_response
        }

        # Notify connected clients
        notify_clients(processing_results)

        return jsonify({'status': 'success', 'results': processing_results})

    except Exception as e:
        print(f"Error processing {file_name}: {str(e)}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

def process_with_gemini(image_content):
    # Encode the image to base64
    image_base64 = base64.b64encode(image_content).decode('utf-8')

    # Set up the model
    model = genai.GenerativeModel('gemini-1.5-flash')

    # Define the prompt
    prompt = """Extract the text from this bill image and present
    it in a clear key-value pair format.
    Provide the data in plain text without any code blocks or formatting tags.
    Ensure accuracy in the extraction of the text from the image.
    Make a new dict of
    line_items: A list of items with the following details:

      item_name: The name of the item.
      quantity: The quantity of the item.
      rate: The rate per item.
      amount: The total amount for the item.

    total_discounts: total discounts in the bill
    total_taxes: total taxes in the bill

    """

    # Generate content
    response = model.generate_content([prompt, {'mime_type': 'image/jpeg', 'data': image_base64}])

    return response.text

def send_to_connection(connection_id, data):
    try:
        api_gateway_args = get_boto3_client_args()
        api_gateway_args['endpoint_url'] = f"https://{WEBSOCKET_API}.execute-api.{AWS_REGION}.amazonaws.com/production"

        apigateway_management = boto3.client('apigatewaymanagementapi', **api_gateway_args)
        apigateway_management.post_to_connection(
            ConnectionId=connection_id,
            Data=json.dumps(data)
        )
    except Exception as e:
        print(f"Error sending message to connection {connection_id}: {str(e)}")
        # If the connection is no longer available, remove it from the database
        if 'GoneException' in str(e):
            dynamodb.Table(CONNECTIONS_TABLE).delete_item(Key={'connectionId': connection_id})

def notify_clients(data):
    connections_table = dynamodb.Table(CONNECTIONS_TABLE)

    # Query the connections table for the specific file name using the GSI
    response = connections_table.query(
        IndexName='FileNameIndex',
        KeyConditionExpression=boto3.dynamodb.conditions.Key('fileName').eq(data['fileName'])
    )

    for item in response['Items']:
        send_to_connection(item['connectionId'], data)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)