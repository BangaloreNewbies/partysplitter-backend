import json
import os
import urllib.request

def handler(event, context):
    alb_dns = os.environ['ALB_DNS']
    secret_key = os.environ['SECRET_KEY']

    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        url = f"http://{alb_dns}/api/process_image"
        data = json.dumps({"fileName": key}).encode('utf-8')
        headers = {
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {secret_key}'
        }
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')

        try:
            with urllib.request.urlopen(req) as response:
                print(response.read().decode('utf-8'))
        except Exception as e:
            print(f"Error calling API: {str(e)}")
