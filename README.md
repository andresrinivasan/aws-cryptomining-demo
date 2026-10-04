# AWS Cryptomining Detection & Response Demo

A demonstration of automated security incident response using AWS security services (GuardDuty, Security Hub, EventBridge) integrated with [Tines 3B](https://www.tines.com/) workflow automation.

## Overview

This repository contains infrastructure-as-code and prompts for building a complete end-to-end demo of cryptomining detection and automated response. The demo simulates a cryptocurrency mining attack detected by AWS GuardDuty, then automatically investigates, isolates, and remediates the threat through a Tines workflow.

**What gets built:**
1. **AWS Infrastructure** - Simulated attack environment with GuardDuty findings
2. **Tines Workflow** - Automated incident response workflow
3. **EventBridge Integration** - Real-time finding routing from AWS to Tines

## Architecture

```text
GuardDuty Finding → Security Hub → EventBridge → Tines Webhook
                                                        ↓
                                                 Tines Workflow:
                                                 1. Enrich (CloudTrail)
                                                 2. Update Security Hub
                                                 3. Isolate (Security Group)
                                                 4. Revoke (IAM Policy)
```

### Key Components

- **Beacon Lambda**: Generates sample GuardDuty findings every 3 minutes
- **Simulated EC2 Instance**: Target of the "attack" (no actual malicious activity)
- **Seeder IAM Role**: Compromised role used to launch the instance
- **Tines Workflow**: Automated response orchestration
- **EventBridge Rules**: Routes findings to Tines in real-time

### Network Architecture

```
VPC (10.0.0.0/16)
├── Private Subnet (10.0.1.0/24)
│   └── Simulated EC2 Instance (t3.nano)
│       ├── eth0 (Primary ENI) - auto-assigned private IP
│       └── eth1 (Secondary ENI) - auto-assigned private IP
├── Public Subnet (10.0.2.0/24)
│   └── Internet Gateway
└── Security Groups
    └── Instance SG (deny-all)

Note: Lambda functions run outside the VPC for simplicity and cost savings.
```

## Prerequisites

Before deploying this stack, ensure:

1. **AWS Account Access**: Admin-level permissions (or sufficient IAM permissions for VPC, EC2, IAM, Lambda, Security Hub, EventBridge, GuardDuty)

2. **GuardDuty Enabled**: Must be enabled in your target region
   ```bash
   # Check if GuardDuty is enabled
   aws guardduty list-detectors --region us-west-1
   
   # If empty, enable it:
   aws guardduty create-detector --enable --region us-west-1
   ```

3. **AWS CLI Configured**: With credentials for your target account

4. **Tines 3B Tenant**: Provisioned (for workflow integration)

5. **Region Selected**: This demo is region-agnostic but you must choose one

## Quick Start

**TL;DR** - Deploy with one command:

```bash
./deploy.sh
```

Or use Make:

```bash
make deploy
```

### Available Commands

```bash
make help            # Show all available commands
make deploy          # Deploy the infrastructure
make verify          # Run verification checks
make enable-beacon   # Enable beacon schedule
make disable-beacon  # Disable beacon schedule
make logs            # Tail beacon Lambda logs
make outputs         # Show stack outputs
make status          # Show stack status
make finding         # Show Security Hub finding
make clean           # Delete the stack
```

Or use the deploy script directly:

```bash
./deploy.sh --help   # Show all options
```

## Getting Started

Follow these steps to build the complete demo:

### 1. Infrastructure Setup

Deploy the AWS infrastructure using the provided deployment script.

**Quick Deploy:**
```bash
./deploy.sh
```

**With Options:**
```bash
# Custom region
./deploy.sh --region us-east-1

# Deploy and enable beacon immediately
./deploy.sh --enable-beacon

# Deploy with verification checks
./deploy.sh --verify
```

**Using Make:**
```bash
make deploy              # Deploy with defaults
make deploy-with-beacon  # Deploy with beacon enabled
make deploy-verify       # Deploy and verify
```

**What it creates:**

- Dedicated VPC with private subnets
- Simulated EC2 instance with dual network interfaces
- IAM seeder role with temporary credentials
- Beacon Lambda (generates sample findings)
- GuardDuty detector lookup
- CloudTrail event seeding
- SSM parameter with simulation manifest

**Key Feature**: Automatic user identity detection - no manual parameters required. The template discovers your AWS identity via `sts:GetCallerIdentity` and creates uniquely-named resources.

**Identity Detection:**
The template automatically supports:
- IAM user: `arn:aws:iam::123456789012:user/asrinivasan@tines.io` → `asrinivasan-tines-io`
- Assumed role: `arn:aws:sts::123456789012:assumed-role/OpsRole/asrinivasan@tines.io` → `asrinivasan-tines-io`
- SSO federated: `arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_*/asrinivasan@tines.io` → `asrinivasan-tines-io`

**View Stack Outputs:**
```bash
make outputs
```

Key outputs include:
- `UserIdentifier`: Sanitized user identity
- `SimulatedInstanceId`: EC2 instance ID
- `SeederRoleArn`: IAM seeder role ARN
- `ApiDestinationInvokeRoleArn`: EventBridge invoke role
- `BeaconScheduleRuleName`: EventBridge rule for beacon

### 2. Enable Beacon

The beacon is **disabled by default**. Enable when ready to start the demo:

```bash
make enable-beacon
```

**What happens:**
- Beacon Lambda runs every 3 minutes
- Creates GuardDuty sample finding: `CryptoCurrency:EC2/BitcoinTool.B!DNS`
- Finding appears in Security Hub
- Beacon checks Security Hub status before each invocation
- If finding status is `NOTIFIED`, beacon pauses (workflow already handled it)

**To disable:**
```bash
make disable-beacon
```

### 3. Workflow Creation

Use [prompts/crypto-mining-incident-workflow-prompt.md](prompts/crypto-mining-incident-workflow-prompt.md) to build the Tines workflow.

**What it does:**

1. **Receives** Security Hub finding via webhook
2. **Enriches** by querying CloudTrail for the intrusion source
3. **Updates** Security Hub status to NOTIFIED
4. **Isolates** instance by applying deny-all security group
5. **Revokes** compromised role credentials via inline deny policy

**Deliverable**: Tines webhook URL (needed for EventBridge routing)

### 4. EventBridge Integration

Use [prompts/eventbridge-routing-prompt.md](prompts/eventbridge-routing-prompt.md) to wire up real-time routing.

**What it configures:**

- EventBridge Connection (API authentication)
- API Destination (Tines webhook endpoint)
- EventBridge Rule (finding pattern matching)

**Result**: GuardDuty findings automatically trigger the Tines workflow within seconds.

## Demo Flow

1. **Beacon fires** (every 3 minutes) → generates GuardDuty sample finding
2. **GuardDuty** publishes to Security Hub
3. **Security Hub** emits finding as EventBridge event
4. **EventBridge** routes to Tines via API Destination
5. **Tines workflow** executes:
   - Queries CloudTrail for `RunInstances` events
   - Identifies compromised IAM role (seeder role)
   - Updates Security Hub finding status to NOTIFIED
   - Applies deny-all security group to instance
   - Attaches inline deny policy to seeder role
6. **Beacon detects NOTIFIED status** → stops generating new findings

## Verification

Wait **3-5 minutes** after enabling the beacon for the first invocation.

### Quick Verify

```bash
make verify
```

This runs all verification checks automatically.

### Manual Verification

#### 1. Verify Beacon Lambda Logs

```bash
make logs
```

**Expected output:**
```
2026-10-03T12:34:56Z START RequestId: abc-123-def-456
2026-10-03T12:34:56Z Beacon invoked at 2026-10-03T12:34:56Z
2026-10-03T12:34:56Z Detector ID: 12abc34d56e78f90...
2026-10-03T12:34:57Z Creating sample GuardDuty finding...
2026-10-03T12:34:57Z Sample finding created successfully
```

### 2. Verify Security Hub Finding

```bash
# Get instance ARN from stack outputs
INSTANCE_ARN=$(aws cloudformation describe-stacks \
  --region $AWS_REGION \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceArn`].OutputValue' \
  --output text)

# Query Security Hub for crypto-mining finding
aws securityhub get-findings \
  --region $AWS_REGION \
  --filters '{
    "ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],
    "Type":[{"Value":"TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS","Comparison":"EQUALS"}],
    "ResourceId":[{"Value":"'$INSTANCE_ARN'","Comparison":"EQUALS"}]
  }' \
  --query 'Findings[0].{Id:Id,Status:Workflow.Status,Severity:Severity.Label}' \
  --output table
```

**Expected:** Finding with `Status=NEW`, `Severity=HIGH`

**Note:** The finding type transforms from GuardDuty's `CryptoCurrency:EC2/BitcoinTool.B!DNS` to Security Hub's ASFF format: `TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS` (slash becomes dash).

### 3. Verify CloudTrail Seeding

```bash
# Query CloudTrail Event History for RunInstances events
aws cloudtrail lookup-events \
  --region $AWS_REGION \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
  --max-results 10 \
  --query 'Events[].[EventTime,Username]' \
  --output text | grep ASIA
```

**Expected:** At least one `RunInstances` event with ASIA* access key from the last 90 days

### 4. Verify SSM Manifest Parameter

```bash
# Get user identifier
USER_ID=$(aws cloudformation describe-stacks \
  --region $AWS_REGION \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`UserIdentifier`].OutputValue' \
  --output text)

# Read manifest
aws ssm get-parameter \
  --region $AWS_REGION \
  --name /cryptomining-demo/${USER_ID}/manifest \
  --query 'Parameter.Value' \
  --output text | jq .
```

**Expected:** JSON with `instance.id`, `seeder.access_key_id` (ASIA*), `seeder.principal_arn`

## Troubleshooting

### Issue: Stack creation fails with "GuardDuty detector not found"

**Cause:** GuardDuty is not enabled in the target region

**Fix:** Enable GuardDuty before deploying:
```bash
aws guardduty create-detector --enable --region $AWS_REGION
```

Then delete the failed stack and redeploy.

### Issue: Beacon Lambda shows no logs

**Cause:** Beacon schedule is disabled (default state)

**Fix:** Enable the beacon schedule:
```bash
BEACON_RULE=$(aws cloudformation describe-stacks \
  --region $AWS_REGION \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
  --output text)

aws events enable-rule --region $AWS_REGION --name $BEACON_RULE
```

### Issue: Security Hub findings not appearing

**Cause 1:** Beacon hasn't run yet (runs every 3 minutes)

**Fix:** Wait 3-5 minutes after enabling beacon, check beacon logs

**Cause 2:** GuardDuty product integration not enabled

**Fix:** List enabled products:
```bash
aws securityhub list-enabled-products-for-import --region $AWS_REGION
```

Expected: `arn:aws:securityhub:us-west-1::product/aws/guardduty`

If missing, enable in Security Hub console: Integrations → Enable GuardDuty

### Issue: Stack deletion fails on VPC

**Cause:** ENI from EC2 instance still attached

**Fix:** Manually detach secondary ENI:
```bash
# Get secondary ENI ID
SECONDARY_ENI=$(aws cloudformation describe-stacks \
  --region $AWS_REGION \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SecondaryEniId`].OutputValue' \
  --output text)

# Get attachment ID
ATTACHMENT_ID=$(aws ec2 describe-network-interfaces \
  --region $AWS_REGION \
  --network-interface-ids $SECONDARY_ENI \
  --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
  --output text)

# Detach ENI
aws ec2 detach-network-interface \
  --region $AWS_REGION \
  --attachment-id $ATTACHMENT_ID \
  --force

# Wait and retry stack deletion
sleep 30
aws cloudformation delete-stack --region $AWS_REGION --stack-name $STACK_NAME
```

### Issue: Two users' findings are indistinguishable

**Cause:** Multiple users deploying to the same AWS account

**Solution:** Filter by `ResourceId` (instance ARN), which includes the unique instance ID per stack.

## Cleanup

### Standard Cleanup (Delete Stack)

```bash
make clean
```

This will:
- Disable the beacon
- Delete the CloudFormation stack
- Wait for deletion to complete
- Confirm before proceeding

**What gets deleted:**
- VPC, subnets, route tables, internet gateway
- EC2 instance and network interfaces
- Lambda functions and log groups
- IAM roles
- EventBridge rules
- SSM parameters

**What persists:**
- Security Hub findings (must archive manually, see below)
- CloudTrail Event History (auto-expires after 90 days)
- CloudWatch Logs (7-day retention, then auto-deleted)

### Archive Security Hub Findings Before Deletion

If you want to clean up findings before deleting the stack:

```bash
# Get instance ARN and finding data
INSTANCE_ARN=$(aws cloudformation describe-stacks \
  --region $AWS_REGION \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceArn`].OutputValue' \
  --output text)

FINDING_DATA=$(aws securityhub get-findings \
  --region $AWS_REGION \
  --filters '{
    "ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],
    "ResourceId":[{"Value":"'$INSTANCE_ARN'","Comparison":"EQUALS"}]
  }' \
  --query 'Findings[0].{Id:Id,ProductArn:ProductArn}' \
  --output json)

FINDING_ID=$(echo $FINDING_DATA | jq -r '.Id')
PRODUCT_ARN=$(echo $FINDING_DATA | jq -r '.ProductArn')

# Archive finding
aws securityhub batch-update-findings \
  --region $AWS_REGION \
  --finding-identifiers Id=$FINDING_ID,ProductArn=$PRODUCT_ARN \
  --workflow Status=RESOLVED \
  --note Text="Demo completed, archiving finding",UpdatedBy="$STACK_NAME"

# Then delete stack
aws cloudformation delete-stack --region $AWS_REGION --stack-name $STACK_NAME
```

## Cost Estimate

**Per deployment per month** (assuming beacon runs continuously):

| Resource | Monthly Cost |
|----------|--------------|
| EC2 t3.nano (730 hrs) | $3.80 |
| Lambda Invocations + Duration | $0.00 (free tier) |
| CloudWatch Logs (~100 MB) | $0.05 |
| Security Hub Findings | $0.00 (no standards) |
| **TOTAL** | **~$3.85/month** |

**Cost Optimization:**
- **Disable beacon when not demoing** - Saves minimal (mostly CloudWatch Logs)
- **Delete stack when not in use** - Zero cost, redeploy takes 5-8 minutes
- **No VPC endpoints needed** - Lambda runs outside VPC, accesses AWS APIs directly

## Key Features

### Multi-User Support

The infrastructure is designed for shared AWS accounts where multiple Tines SEs may deploy simultaneously. Resources are tagged with deployer identity and use unique naming conventions.

### Security Best Practices

- No public IPs on simulated instances
- Private subnets only
- Deny-all security groups
- Least-privilege IAM policies
- Temporary credentials only (ASIA* prefix, not AKIA*)

### Cost Optimization

- Lambda functions outside VPC (no VPC endpoints needed, faster cold starts)
- t3.nano instances (minimal compute cost)
- CloudTrail Event History (free, no trail required)
- Beacon schedule disabled by default
- No NAT Gateway or VPC endpoints (~$22/month saved)

## Technical Details

### Finding Type Transformation

GuardDuty finding type `CryptoCurrency:EC2/BitcoinTool.B!DNS` transforms to Security Hub ASFF type `TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS` (slash becomes dash).

### CloudTrail Event History

**Important:** This solution does NOT require CloudTrail trails.

CloudTrail Event History is:
- **Enabled by default** in every AWS account (cannot be disabled)
- **Free** (no charges for Event History or `LookupEvents` API calls)
- **90-day retention** (sufficient for real-time incident response)
- **Automatic** (no trail configuration needed)

The Tines workflow queries Event History via the `cloudtrail:LookupEvents` API.

### Lambda Functions Summary

| Function | Runtime | Timeout | Purpose |
|----------|---------|---------|---------|
| IdentityDetectorLambda | Python 3.13 | 60s | Detect deployer identity |
| SecurityHubEnablerLambda | Python 3.13 | 120s | Enable Security Hub |
| GuardDutyDetectorLookupLambda | Python 3.13 | 60s | Lookup GuardDuty detector |
| CloudTrailSeederLambda | Python 3.13 | 300s | Seed CloudTrail with temp creds |
| BeaconLambda | Python 3.13 | 60s | Generate sample findings |

## License

This demo is provided as-is for educational and demonstration purposes.

## Support

For issues or questions:
1. Check [Troubleshooting](#troubleshooting) section above
2. Review CloudFormation events: `aws cloudformation describe-stack-events --stack-name $STACK_NAME`
3. Check Lambda logs: `aws logs tail /aws/lambda/cryptomining-demo-${USER_ID}-*`
4. Open a GitHub issue in this repository