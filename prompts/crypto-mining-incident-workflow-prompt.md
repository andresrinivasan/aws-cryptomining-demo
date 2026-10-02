# Crypto-Mining Incident Response Workflow

Build a Tines 3B workflow that handles cryptocurrency mining detection and automated response.

## Required Parameters
- **Workflow Name**: `Crypto-Mining Incident Response`
- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]

## Workflow Objectives

Build a workflow that:

1. **Receives** Security Hub crypto-mining finding via webhook (EventBridge format)

2. **Enriches** the finding by discovering the intrusion source:
   - Extract the compromised EC2 instance ID from the finding
   - Query CloudTrail for recent RunInstances events (last 24 hours)
   - Identify events with temporary credentials (access keys starting with ASIA)
   - Extract the assumed role ARN (the "seeder role" that was compromised)
   - Discover all network interfaces attached to the instance

3. **Updates** Security Hub to mark the finding as "NOTIFIED" with a timestamp note

4. **Isolates** the compromised instance at the network level:
   - Create a deny-all security group (no inbound or outbound rules)
   - Apply it to all network interfaces on the instance

5. **Revokes** the compromised credentials:
   - Attach an inline deny-all policy to the seeder role to immediately block its use

6. **Provides testing capability**:
   - Include a separate step (disconnected from main flow) that posts a sample crypto-mining finding to the webhook for manual testing

## Expected Behavior
- Webhook receives finding → enriches with CloudTrail + EC2 data → updates Security Hub → isolates network → revokes credentials
- Each step should log its actions for audit purposes
- The testing step allows manual verification without deploying EventBridge routing

Build this workflow now.
