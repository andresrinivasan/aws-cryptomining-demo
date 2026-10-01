# EventBridge Routing to Tines Webhook

Configure AWS EventBridge to route GuardDuty crypto-mining findings to the Tines workflow.

## Required Parameters
- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]
- **CloudFormation Stack Name**: [USER PROVIDES - e.g., `cryptomining-demo-asrinivasan-tines-io`]
- **Tines Webhook URL**: [USER PROVIDES - from the workflow created in the previous prompt]

## Steps

### 1. Retrieve Infrastructure Details
- Query CloudFormation stack outputs for `ApiDestinationInvokeRoleArn`
- This is the IAM role that EventBridge will assume to POST events to the webhook
- Also note the VPC ID from stack outputs (for reference)

### 2. Create EventBridge Connection
- Name: `cryptomining-demo-tines-connection`
- Description: "Authentication for Tines webhook"
- Authorization type: `API_KEY`
- Extract the `external_id` token from the Tines webhook URL query string
- Configure auth header: `Authorization: Bearer {external_id}`

### 3. Create EventBridge API Destination
- Name: `cryptomining-demo-tines-webhook`
- Description: "Tines crypto-mining incident response workflow"
- Endpoint URL: The Tines webhook URL (full URL including query parameters)
- HTTP method: `POST`
- Connection: Reference the connection created in step 2
- Invocation rate limit: 300 invocations per second

### 4. Create EventBridge Rule
- Name: `cryptomining-demo-to-tines`
- Description: "Route GuardDuty crypto-mining findings to Tines"
- Event bus: `default`
- State: `ENABLED`
- Event pattern:
  ```json
  {
    "source": ["aws.securityhub"],
    "detail-type": ["Security Hub Findings - Imported"],
    "detail": {
      "findings": {
        "ProductName": ["GuardDuty"],
        "Types": [{
          "prefix": "TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B"
        }],
        "Workflow": {
          "Status": ["NEW"]
        }
      }
    }
  }
  ```
- Target: The API destination created in step 3
- Target role ARN: The `ApiDestinationInvokeRoleArn` from step 1

### 5. Verify Configuration
- Check that the EventBridge rule state is `ENABLED`
- Verify the connection status shows as `AUTHORIZED`
- Confirm the API destination endpoint matches the Tines webhook URL

## Expected Behavior
GuardDuty sample finding → Security Hub imports it as ASFF → EventBridge rule matches the pattern → EventBridge assumes the invoke role → EventBridge POSTs to API destination → Tines webhook receives the event → Workflow executes all three tasks

## What the ApiDestinationInvokeRoleArn Does
This IAM role was created by the CloudFormation template with:
- **Trust policy**: Allows `events.amazonaws.com` (EventBridge service) to assume it
- **Permissions**: `events:InvokeApiDestination` scoped to `cryptomining-demo-*` resources

EventBridge doesn't invoke API destinations directly - it needs an IAM role to do so. When the rule fires, EventBridge temporarily assumes this role to POST the event payload to the Tines webhook.

Configure this routing now.
