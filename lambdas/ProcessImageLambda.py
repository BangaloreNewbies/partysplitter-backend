import json
import os
import urllib.request
import urllib.error

def handler(event, context):
    # Determine which URL to use based on the environment
    if 'HOST_SERVICE_URL' in os.environ:
        # Local development environment
        base_url = os.environ['HOST_SERVICE_URL']
    elif 'ALB_DNS' in os.environ:
        # Production environment
        base_url = f"http://{os.environ['ALB_DNS']}"
    else:
        raise EnvironmentError("Neither HOST_SERVICE_URL nor ALB_DNS is set")

    secret_key = os.environ['SECRET_KEY']

    # Debug: Log base URL and masked secret key
    print(f"Debug - Base URL: {base_url}")
    print(f"Debug - Secret Key (masked): {secret_key[:4]}{'*' * (len(secret_key) - 4)}")

    # Extract the file name from the S3 event
    file_name = event['Records'][0]['s3']['object']['key']

    # Prepare the request
    url = f"{base_url}/api/process_image"
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {secret_key}'
    }
    data = json.dumps({"fileName": file_name}).encode('utf-8')

    # Debug: Log the full URL being called
    print(f"Debug - Calling URL: {url}")

    # Make a call to the service
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        with urllib.request.urlopen(req) as response:
            if response.status == 200:
                print("Debug - API call successful")
                return {
                    'statusCode': 200,
                    'body': json.dumps('Image processing initiated successfully')
                }
            else:
                raise urllib.error.HTTPError(url, response.status, 'Unexpected response', response.headers, None)
    except urllib.error.HTTPError as e:
        print(f"HTTP Error calling API: {e.code} {e.reason}")
        return {
            'statusCode': e.code,
            'body': json.dumps(f'Error processing image: {e.reason}')
        }
    except urllib.error.URLError as e:
        print(f"URL Error calling API: {str(e.reason)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error processing image: {str(e.reason)}')
        }
    except Exception as e:
        print(f"Unexpected error calling API: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Unexpected error processing image: {str(e)}')
        }