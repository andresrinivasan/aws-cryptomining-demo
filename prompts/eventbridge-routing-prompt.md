# EventBridge Routing to Tines Webhook

Route GuardDuty crypto-mining findings from AWS Security Hub to a Tines webhook.

## Required Parameters

- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]
- **Tines Webhook URL**: [USER PROVIDES - the webhook URL from the Tines workflow]

## Requirements

Configure EventBridge to send Security Hub findings to the Tines webhook:

1. **Webhook URL**: Use the full Tines webhook URL as-is (authentication is handled via the `external_id` query parameter in the URL)

2. **IAM Role**: EventBridge needs an IAM role to invoke the API destination with:
   - Trust policy allowing `events.amazonaws.com` to assume the role
   - Permission: `events:InvokeApiDestination`

   Check if a suitable role exists (look for CloudFormation stack outputs or existing IAM roles), otherwise create one.

3. **Event Filtering**: Only route findings matching this pattern:

   ```json
   {
     "source": ["aws.securityhub"],
     "detail-type": ["Security Hub Findings - Imported"],
     "detail": {
       "findings": {
         "ProductName": ["GuardDuty"],
         "Types": ["TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS"],
         "Workflow": {
           "Status": ["NEW"]
         }
       }
     }
   }
   ```

## Expected Flow

GuardDuty finding → Security Hub imports as ASFF → EventBridge matches pattern → POSTs to Tines webhook → Workflow executes

Configure this routing now.
