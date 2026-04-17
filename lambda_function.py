import json
import urllib3
import os

WEBHOOK_URL = os.environ['WEBHOOK_URL']
http = urllib3.PoolManager()

def lambda_handler(event, context):
    try:
        sns_message = json.loads(event['Records'][0]['Sns']['Message'])
    except (KeyError, IndexError, json.JSONDecodeError) as e:
        print(f"Failed to parse SNS event: {e}. Raw event: {json.dumps(event)}")
        return {"statusCode": 400, "body": "Malformed SNS event."}

    alarm_name = sns_message.get('AlarmName', 'Unknown Alarm')
    alarm_state = sns_message.get('NewStateValue', 'Unknown State')
    
    alarm_descriptions = {
        "IAM-Security-Alert": "⚠️ A sensitive IAM action (like CreateUser, DeleteUser, or CreateAccessKey) was detected in CloudTrail.",
        "AWS-Billing-Alert": "💰 Your estimated AWS charges have exceeded the $5 threshold."
    }
    
    alarm_reason = alarm_descriptions.get(alarm_name, sns_message.get('NewStateReason', 'Unknown reason'))
    
    # Format specifically for Discord
    payload = {
        "embeds": [
            {
                "title": "🚨 AWS Infrastructure Alert 🚨",
                "color": 15548997,
                "fields": [
                    {
                        "name": "Alarm Name",
                        "value": alarm_name,
                        "inline": False
                    },
                    {
                        "name": "State",
                        "value": f"**{alarm_state}**",
                        "inline": True
                    },
                    {
                        "name": "What Happened?",
                        "value": alarm_reason,
                        "inline": False
                    }
                ]
            }
        ]
    }
    
    try:
        response = http.request(
            'POST',
            WEBHOOK_URL,
            body=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        
        if response.status == 204:
            print("Successfully sent to Discord!")
        else:
            print(f"Failed to send. Status: {response.status}")
            
        return {"statusCode": 200, "body": "Alert processed."}
    except Exception as e:
        print(f"Error sending message: {e}")
        return {"statusCode": 500, "body": "Failed to send alert."}
