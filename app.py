from flask import Flask, request, jsonify
from flask_cors import CORS
from functools import wraps
import boto3
import os
import json
import uuid
import base64
import google.generativeai as genai
from botocore.exceptions import ClientError
import traceback
import re

def check_environment_variables():
    required_vars = [
        "S3_BUCKET", "CONNECTIONS_TABLE", "SECRET_KEY",
        "GOOGLE_API_KEY", "WSS_URL",
        "WEBSOCKET_LAMBDA_NAME"
    ]

    missing_vars = [var for var in required_vars if not os.getenv(var)]

    if missing_vars:
        raise EnvironmentError(f"Missing required environment variables : {', '.join(missing_vars)}")

# Run the check immediately
check_environment_variables()

# Now it's safe to access these variables
S3_BUCKET = os.environ['S3_BUCKET']
CONNECTIONS_TABLE = os.environ['CONNECTIONS_TABLE']
GOOGLE_API_KEY = os.environ['GOOGLE_API_KEY']
SECRET_KEY = os.environ['SECRET_KEY']
WSS_URL = os.environ['WSS_URL']
WEBSOCKET_LAMBDA_NAME = os.environ['WEBSOCKET_LAMBDA_NAME']
ENDPOINT_URL = os.environ.get('ENDPOINT_URL')

app = Flask(__name__)
CORS(app)  # This enables CORS for all routes

# Function to get boto3 client args
def get_boto3_client_args():
    args = {'region_name': AWS_DEFAULT_REGION}
    if ENDPOINT_URL:
        args['endpoint_url'] = ENDPOINT_URL
    return args

# Create AWS clients with the appropriate endpoint URL and region
s3_client = boto3.client('s3', **get_boto3_client_args())
sqs_client = boto3.client('sqs', **get_boto3_client_args())
dynamodb = boto3.resource('dynamodb', **get_boto3_client_args())
lambda_client = boto3.client('lambda', **get_boto3_client_args())

genai.configure(api_key=GOOGLE_API_KEY)

@app.route('/health')
def health_check():
   return 'OK', 200

ALLOWED_EXTENSIONS = {'jpg', 'jpeg', 'png', 'heic', 'tiff'}

@app.route('/api/bill_url', methods=['POST'])
def get_presigned_url():
    data = request.json
    connection_id = data.get('connectionId')
    file_extension = data.get('fileExtension', '').lower()

    if not connection_id:
        return jsonify({'error': 'Connection ID is required'}), 400

    if not file_extension or file_extension not in ALLOWED_EXTENSIONS:
        return jsonify({'error': 'Invalid or missing file extension'}), 400

    # Generate a unique filename with the provided extension
    file_name = f"upload_{str(uuid.uuid4())}.{file_extension}"

    try:
        presigned_url = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': S3_BUCKET,
                'Key': file_name,
                'ContentType': f'image/{file_extension}'
            },
            ExpiresIn=3600,
            HttpMethod='PUT'
        )

        store_file_info(connection_id, file_name)

        return jsonify({
            'uploadUrl': presigned_url,
            'fileName': file_name
        }), 200

    except ClientError as e:
        return jsonify({'error': str(e)}), 500

def store_file_info(connection_id, file_name):
    try:
        connections_table = dynamodb.Table(CONNECTIONS_TABLE)
        connections_table.put_item(
            Item={
                'connectionId': connection_id,
                'fileName': file_name,
                'status': 'pending'
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

    # Check if the file has already been processed
    connections_table = dynamodb.Table(CONNECTIONS_TABLE)
    db_response = connections_table.query(
        IndexName='FileNameIndex',
        KeyConditionExpression=boto3.dynamodb.conditions.Key('fileName').eq(file_name)
    )

    if db_response['Items'] and db_response['Items'][0].get('status') == 'processed':
        return jsonify({'status': 'success', 'message': 'File already processed'}), 200

    try:
        # Download the image from S3
        s3_response = s3_client.get_object(Bucket=S3_BUCKET, Key=file_name)
        image_content = s3_response['Body'].read()

        # Process the image with Gemini 1.5 Flash
        gemini_response = process_with_gemini(image_content)

        # Prepare processing results
        processing_results = {
            'fileName': file_name,
            'gemini_analysis': gemini_response
        }

        # Use existing connectionId if available, otherwise generate a new one
        connection_id = db_response['Items'][0]['connectionId'] if db_response['Items'] else str(uuid.uuid4())

        # Update or create the item in the connections table with the processed status
        connections_table.put_item(
            Item={
                'connectionId': connection_id,
                'fileName': file_name,
                'status': 'processed',
                'results': json.dumps(processing_results)
            }
        )

        # Notify connected clients
        notify_clients(processing_results)
        return jsonify({'status': 'success', 'results': processing_results})

    except Exception as e:
        print(f"Error processing {file_name}: {str(e)}")
        print("Stack trace:")
        traceback.print_exc()
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

    In certain cases, the line item  price is inclusive of taxes, you need to exclude taxes from the price.
    The tax percentage would be in the image for these cases. You can confirm this case by adding up the cost of all line items. If this total
    matches the total amount in the bill, you need to exclude taxes from the price of each line item upto 2 decimal places.
    Make a new json object of
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

    # Extract the content from the JSON structure
    try:
        # Remove any triple backticks and 'json' tags
        cleaned_text = response.text.replace('```json', '').replace('```', '').strip()
        # Parse the cleaned text as JSON
        parsed_content = json.loads(cleaned_text)
        return parsed_content
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}")
        return {"error": "Failed to parse response as JSON", "raw_text": response.text}


def send_to_connection(connection_id, data):
    try:
        # Extract domain and stage from the WebSocket URL
        wss_url = WSS_URL
        match = re.match(r'wss://([^/]+)/([^/]+)', wss_url)
        if not match:
            raise ValueError("Invalid WSS_URL format")

        domain = match.group(1)
        stage = match.group(2)

        # Prepare the event for the WebSocket Lambda
        event = {
            'requestContext': {
                'domainName': domain,
                'stage': stage,
                'routeKey': 'sendMessage',
                'connectionId': connection_id
            },
            'body': json.dumps({
                'type': 'processed_data',
                'payload': data
            })
        }

        # Invoke the WebSocket Lambda
        response = lambda_client.invoke(
            FunctionName=WEBSOCKET_LAMBDA_NAME,
            InvocationType='Event',
            Payload=json.dumps(event)
        )

        # Check the response
        status_code = response['StatusCode']
        if status_code != 202:
            raise Exception(f"Lambda invocation failed with status code: {status_code}")

        print(f"Message sent successfully to connection {connection_id}")
    except Exception as e:
        print(f"Error sending message to connection {connection_id}: {str(e)}")
        # If the connection is no longer available, remove it from the database
        if 'GoneException' in str(e) or '410' in str(e):
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