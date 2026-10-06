# Infrastructure Prompt (Fixed)

You are setting up AWS infrastructure for an AWS and Tines 3B demo. The exercise simulates a cryptocurrency mining attack detected by GuardDuty with an intelligent workflow implemented in Tines 3B.

## CONTEXT

1. This is a demo in accounts Tines owns
2. GuardDuty findings are Security Hub *records*, not actual attacks
3. Nothing executes on hosts, no traffic generated, no real domains contacted
4. Multiple Tines SEs may deploy this demo simultaneously in the same AWS account
5. The CloudFormation template you generate must be deterministic and repeatable

## EXPECTATIONS

1. **Resource Tagging**: All resources must be tagged with a `user` tag. The value is the authenticated principal identifier (IAM user name, assumed role session name, or federated identity) of who is deploying this template.

2. **Repeatability**: Use CloudFormation with custom resources and Lambda-backed resources to set up infrastructure. The template must be idempotent.

3. **Region-Agnostic**: Do not hard-code regions or account IDs. Use CloudFormation pseudo-parameters (`AWS::Region`, `AWS::AccountId`, `AWS::StackName`) and `Fn::Sub` / `Fn::Join` to dynamically resolve values. The template deploys to the region where the CloudFormation stack is created.

4. **Naming Convention**: For resources that require names, use the prefix `cryptomining-demo-` and append a sanitized user identifier. 
   - **Automatic Identity Detection**: Custom resource Lambda calls `sts:GetCallerIdentity` to discover deploying user's identity
   - **Identity Parsing**: Extract user identifier from IAM ARN:
     - IAM user: `arn:aws:iam::123456789012:user/asrinivasan@tines.io` → extract `asrinivasan@tines.io`
     - Assumed role: `arn:aws:sts::123456789012:assumed-role/OpsRole/asrinivasan@tines.io` → extract session name `asrinivasan@tines.io`
     - SSO federated: `arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_*/asrinivasan@tines.io` → extract session name
   - **Automatic Sanitization**: Convert to `user-domain` format:
     - If identifier contains `@` (email-like): remove `@`, replace `.` with `-`
     - If no `@` (plain username): use as-is with `.` → `-` replacement
     - Example: `asrinivasan@tines.io` → `asrinivasan-tines-io`
   - Example IAM role name: `cryptomining-demo-asrinivasan-tines-io-seeder`
   - Example SSM parameter: `/cryptomining-demo/asrinivasan-tines-io/manifest`
   - For resources that cannot be named, use a tag: `Name=cryptomining-demo-{user}`, `user={raw-identifier}`

5. **Stack Naming Convention**: Deploying user should name the stack as: `cryptomining-demo-{user-domain}` (e.g., `cryptomining-demo-asrinivasan-tines-io`) but this is optional - the template will work with any stack name

## PREREQUISITES

Before deploying this template, ensure:
- AWS account has admin-level access (or sufficient permissions to create VPC, EC2, IAM, Lambda, Security Hub, EventBridge resources)
- GuardDuty detector is enabled in the target region (template will look it up)
- No conflicting `cryptomining-demo-{your-identifier}` stack exists
- Tines 3B tenant is provisioned (template outputs will be used in Tines workflow configuration)

## SETUP REQUIREMENTS

### 0. DETECT AND SANITIZE USER IDENTITY (CloudFormation Custom Resource)

**Purpose**: Automatically discover deploying user's identity and convert to valid AWS resource name format.

**Mechanism**:
1. Custom resource Lambda calls `sts:GetCallerIdentity` to get deploying principal's ARN
2. Parse ARN to extract user identifier based on ARN type
3. Sanitize identifier to `user-domain` format
4. Return both raw and sanitized identifiers as custom resource attributes

**No CloudFormation Parameters Required** - fully automatic detection.

**Example CloudFormation**:
```yaml
Resources:
  IdentityDetector:
    Type: AWS::CloudFormation::CustomResource
    Properties:
      ServiceToken: !GetAtt IdentityDetectorLambda.Arn
      # No input parameters - Lambda calls sts:GetCallerIdentity

  # All other resources reference:
  # !GetAtt IdentityDetector.UserIdentifier (sanitized: asrinivasan-tines-io)
  # !GetAtt IdentityDetector.RawIdentity (raw: asrinivasan@tines.io)
```

**Lambda Logic** (Python):
```python
import boto3
import re

def extract_identity(arn):
    """Extract user identifier from IAM/STS ARN."""
    # IAM user: arn:aws:iam::123456789012:user/asrinivasan@tines.io
    if ':user/' in arn:
        return arn.split(':user/')[-1]
    
    # Assumed role: arn:aws:sts::123456789012:assumed-role/RoleName/SessionName
    if ':assumed-role/' in arn:
        parts = arn.split(':assumed-role/')[-1].split('/')
        if len(parts) >= 2:
            return parts[1]  # Session name (often email for SSO)
        return parts[0]  # Role name if no session
    
    # Fallback: extract last segment
    return arn.split('/')[-1]

def sanitize_identifier(identifier):
    """Convert identifier to user-domain format for AWS resource names."""
    # Remove @ and replace . with -
    sanitized = identifier.replace('@', '-').replace('.', '-')
    # Remove any other invalid characters for IAM names
    sanitized = re.sub(r'[^a-zA-Z0-9-]', '-', sanitized)
    return sanitized.lower()

def handler(event, context):
    sts = boto3.client('sts')
    identity = sts.get_caller_identity()
    arn = identity['Arn']
    
    raw_identifier = extract_identity(arn)
    sanitized = sanitize_identifier(raw_identifier)
    
    return {
        'Data': {
            'RawIdentity': raw_identifier,
            'UserIdentifier': sanitized,
            'CallerArn': arn,
            'AccountId': identity['Account']
        }
    }
```

**IAM Permissions** (Lambda execution role):
- `sts:GetCallerIdentity` (no resource ARN, implicitly allowed for Lambda in VPC)

### 1. ENABLE SECURITY HUB CSPM (CloudFormation Custom Resource)

**Do NOT use manual CLI command.** Create a CloudFormation custom resource Lambda that:
- Checks if Security Hub is already enabled (`securityhub:DescribeHub`)
- If not enabled: calls `securityhub:EnableSecurityHub` with `--no-enable-default-standards`
- Verifies GuardDuty product integration auto-enabled
- On stack deletion: optionally disables Security Hub (make this configurable via parameter `CleanupSecurityHub` default: false)

**Rationale**: DO NOT enable FSBP/CIS standards (generates thousands of control findings + AWS Config costs).

### 2. CREATE DEDICATED VPC

Create a new VPC with:
- CIDR: 10.0.0.0/16
- **Private subnet** (10.0.1.0/24) for EC2 instance - NO public IP, NO internet access
- Public subnet (10.0.2.0/24) for NAT Gateway (if needed for Lambda to reach AWS APIs)
- VPC endpoints for EC2, Security Hub, GuardDuty, SSM (to avoid NAT Gateway costs)
- Tag: `Name=cryptomining-demo-{user}-vpc`

**Security**: Instance in private subnet with no public IP prevents accidental exposure.

### 3. CREATE BEACON LAMBDA

**Function**: Python 3.14, inline code (ZipFile in CloudFormation)

**Schedule**: EventBridge rule with `rate(3 minutes)` - **controllable via parameter**
- CloudFormation parameter: `BeaconEnabled` (Type: String, AllowedValues: [ENABLED, DISABLED], Default: DISABLED)
- EventBridge rule `State` property maps to this parameter
- **Rationale**: Prevents beacon from firing immediately on every deploy; user must explicitly enable

**Purpose**: 
- Calls `securityhub:BatchImportFindings` to create synthetic GuardDuty findings with type `CryptoCurrency:EC2/BitcoinTool.B!DNS`
- Uses real EC2 instance metadata (not fabricated IDs like CreateSampleFindings)
- Constructs full ASFF (AWS Security Finding Format) finding in code
- Checks if finding still at `Workflow.Status=NEW` via `securityhub:GetFindings`
- If finding status is `NOTIFIED`, Lambda exits early (stops generating new samples)
- Finding appears identical to real GuardDuty findings (no `Sample: true` flag)

**IAM Permissions** (Lambda execution role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "securityhub:BatchImportFindings",
        "securityhub:BatchUpdateFindings",
        "securityhub:GetFindings",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

**Environment Variables**:
- `DETECTOR_ID`: Discovered via custom resource (see #7 below)
- `PRODUCT_ARN`: `arn:aws:securityhub:${AWS::Region}:${AWS::AccountId}:product/${AWS::AccountId}/default`
- `INSTANCE_ID`: `!Ref SimulatedInstance`
- `INSTANCE_ARN`: `!Sub 'arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${SimulatedInstance}'`
- `INSTANCE_TYPE`: `'t3.nano'`
- `INSTANCE_PRIVATE_IP`: `!GetAtt SimulatedInstance.PrivateIp`
- `VPC_ID`: `!Ref DemoVPC`
- `SUBNET_ID`: `!Ref PrivateSubnet`
- `IMAGE_ID`: `!Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'`
- `IAM_INSTANCE_PROFILE_ARN`: `!GetAtt SimulatedInstanceProfile.Arn`
- `REGION`: `!Ref AWS::Region`
- `AWS_ACCOUNT_ID`: `!Ref AWS::AccountId`
- `USER_IDENTIFIER`: `!GetAtt IdentityDetector.UserIdentifier` (for filtering findings by user in shared account)

**CloudWatch Alarm**: Create alarm if beacon Lambda errors exceed 2 in 5 minutes (indicates beacon malfunction).

### 4. CREATE API DESTINATION INVOKE ROLE

**Service Principal**: `events.amazonaws.com` (NOT events.cryptomining.amazonaws.com)

**Policy**: Scoped to this stack's resources only (not wildcard):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "events:InvokeApiDestination",
      "Resource": {
        "Fn::Sub": "arn:aws:events:${AWS::Region}:${AWS::AccountId}:api-destination/cryptomining-demo-${IdentityDetector.UserIdentifier}-*"
      }
    }
  ]
}
```

**Export**: CloudFormation stack output `ApiDestinationInvokeRoleArn`

### 5. SEED SIMULATION RESOURCES

#### 5a. EC2 Instance (Simulated Crypto-Mining Target)

- **Instance Type**: t3.nano
- **AMI**: Latest Amazon Linux 2023 (use `aws ssm get-parameter` to look up in custom resource)
- **VPC**: Use the dedicated VPC created in #2, **private subnet**
- **Network Interfaces**: 
  - Primary ENI (eth0): Created automatically by `AWS::EC2::Instance`
  - Secondary ENI (eth1): Create separate `AWS::EC2::NetworkInterface` resource, then attach via `AWS::EC2::NetworkInterfaceAttachment` with `DeviceIndex: 1`
- **Security Group**: Deny-all (no inbound, no outbound) - instance doesn't need connectivity
- **Tags**: `Name: !Sub 'cryptomining-demo-${IdentityDetector.UserIdentifier}-target'`, `user: !GetAtt IdentityDetector.RawIdentity`, `Purpose: sim-target`

#### 5b. IAM Seeder Role

**Role Name**: `!Sub 'cryptomining-demo-${IdentityDetector.UserIdentifier}-seeder'`

**Trust Policy**: Allow Lambda execution role from CloudTrail-seeding custom resource to assume:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${AWS::AccountId}"
        }
      }
    }
  ]
}
```

**Seeder Role Permissions** (least-privilege):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudTrailSeeding",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleForInstanceProfile",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    }
  ]
}
```

**Note**: Seeder is an IAM role that uses temporary session credentials (ASIA* prefix) from `sts:AssumeRole`, NOT long-term access keys (AKIA* prefix). The custom resource Lambda assumes this role to seed CloudTrail.

#### 5c. SSM Parameter (Simulation Manifest)

**Parameter Name**: `!Sub '/cryptomining-demo/${IdentityDetector.UserIdentifier}/manifest'`

**Value** (JSON):
```json
{
  "version": 1,
  "account": "${AWS::AccountId}",
  "region": "${AWS::Region}",
  "stack_name": "${AWS::StackName}",
  "detector_id": "<discovered-detector-id>",
  "instance": {
    "id": "<instance-id>",
    "type": "t3.nano",
    "vpc_id": "<vpc-id>",
    "eni_ids": ["<eth0-eni-id>", "<eth1-eni-id>"]
  },
  "seeder": {
    "principal_arn": "<seeder-role-arn>",
    "access_key_id": "<ASIA-temp-credential-from-seeding-session>",
    "role_name": "cryptomining-demo-{user-domain}-seeder"
  },
  "seeded_at": "<ISO-8601-timestamp>"
}
```

**Tags**: `Name=cryptomining-demo-{user}-manifest`, `user={user}`

#### 5d. CloudTrail Seeding (Custom Resource Lambda)

**Purpose**: Seed CloudTrail with `RunInstances` events so Tines workflow can query access key.

**Mechanism**: 
1. Custom resource Lambda has execution role with `sts:AssumeRole` permission
2. Lambda assumes the seeder role (from 5b)
3. While assumed, calls `ec2:RunInstances` to launch a t3.nano (smallest/cheapest)
4. Captures the temporary ASIA* access key from the assumed role session
5. Immediately terminates the seeded instance (to avoid costs)
6. Writes access key ID to SSM parameter manifest

**Timing**: Runs during CloudFormation stack creation, after seeder role and VPC are created (use `DependsOn`).

**On Stack Deletion**: No cleanup action (CloudTrail events persist for 90 days but are harmless).

### 6. DISCOVER GUARDDUTY DETECTOR (Custom Resource Lambda)

**Purpose**: Look up existing GuardDuty detector ID in the current region.

**Mechanism**:
1. Custom resource Lambda calls `guardduty:ListDetectors`
2. If detectors exist, return the first detector ID
3. If no detectors exist, fail with clear error: "GuardDuty is not enabled in this region. Please enable GuardDuty before deploying this stack."

**Output**: Detector ID is stored in custom resource attribute and passed to beacon Lambda environment variable.

### 7. VERIFY CLOUDTRAIL EVENT HISTORY (AUTOMATIC)

**Important**: This solution does NOT require CloudTrail trails.

CloudTrail Event History is:
- **Enabled by default** in every AWS account (cannot be disabled)
- **Free** (no charges for Event History storage or `LookupEvents` API calls)
- **90-day retention** (sufficient for real-time incident response)
- **Automatic** (no trail configuration needed)

The Tines workflow queries Event History via `cloudtrail:LookupEvents` API, which works without any trails configured.

**Verification Command** (post-deployment):
```bash
aws cloudtrail lookup-events \
  --region ${AWS::Region} \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
  --max-results 1
```

Expected: Returns at least one `RunInstances` event from the CloudTrail seeding step.

## CONSTRAINTS

- AWS Organizations SCP blocks `iam:CreateUser` and `iam:CreateAccessKey` (use roles with temporary credentials)
- Security Hub finding type transforms from `CryptoCurrency:EC2/BitcoinTool.B!DNS` → `TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS` (slash becomes dash in ASFF)
- IAM role/user names cannot contain `@` or `.` characters (must sanitize email addresses)
- EC2 instance must be in private subnet with no public IP (security best practice)

## STACK OUTPUTS

Export the following CloudFormation outputs for use in Tines workflow configuration:

1. **ApiDestinationInvokeRoleArn**: ARN of EventBridge API destination invoke role
2. **SeederRoleArn**: ARN of IAM seeder role (target for Task 3 credential revocation)
3. **SimulatedInstanceId**: EC2 instance ID (target for Task 2 containment)
4. **SimulatedInstanceArn**: Full EC2 instance ARN (used in GuardDuty finding)
5. **PrimaryEniId**: Primary network interface ID (eth0)
6. **SecondaryEniId**: Secondary network interface ID (eth1)
7. **SimulationManifestParameter**: SSM parameter name (e.g., `/cryptomining-demo/{user}/manifest`)
8. **BeaconScheduleRuleName**: EventBridge rule name for manual enable/disable
9. **GuardDutyDetectorId**: Discovered detector ID
10. **VpcId**: Created VPC ID
11. **UserIdentifier**: Sanitized user identifier (`user-domain` format, e.g., `asrinivasan-tines-io`)
12. **RawIdentity**: Raw identity string extracted from ARN (e.g., `asrinivasan@tines.io` or `OpsRole`)
13. **DeployerArn**: Full ARN of the deploying principal (for audit trail)

## VERIFICATION (Post-Deployment Checklist)

Run these commands after stack creation completes. **Timing**: Wait 3 minutes after enabling beacon schedule for first invocation.

### 1. Verify Beacon Lambda is Logging
```bash
aws logs tail /aws/lambda/cryptomining-demo-${USER}-beacon \
  --region ${AWS::Region} \
  --follow \
  --since 5m
```
**Expected**: Log entries showing "Importing synthetic finding via BatchImportFindings" or "Finding already NOTIFIED, beacon paused"

### 2. Verify Security Hub Finding Exists
```bash
aws securityhub get-findings \
  --region ${AWS::Region} \
  --filters '{
    "ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],
    "Type":[{"Value":"TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS","Comparison":"EQUALS"}],
    "ResourceId":[{"Value":"arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${INSTANCE_ID}","Comparison":"EQUALS"}]
  }' \
  --query 'Findings[0].{Id:Id,Status:Workflow.Status,Severity:Severity.Label}' \
  --output table
```
**Expected**: One finding with `Status=NEW`, `Severity=HIGH`, `Id=<uuid>`

### 3. Verify CloudTrail Seeding Succeeded
```bash
aws cloudtrail lookup-events \
  --region ${AWS::Region} \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
  --max-results 5 \
  --query 'Events[].{Time:EventTime,AccessKey:CloudTrailEvent}' \
  --output json | \
  jq -r '.[] | .Time + " " + (.AccessKey | fromjson | .userIdentity.accessKeyId)'
```
**Expected**: At least one `RunInstances` event with ASIA* access key in last 90 days

### 4. Verify SSM Manifest Parameter
```bash
# Get UserIdentifier from stack outputs first
USER_ID=$(aws cloudformation describe-stacks \
  --region ${AWS::Region} \
  --stack-name <your-stack-name> \
  --query 'Stacks[0].Outputs[?OutputKey==`UserIdentifier`].OutputValue' \
  --output text)

aws ssm get-parameter \
  --region ${AWS::Region} \
  --name /cryptomining-demo/${USER_ID}/manifest \
  --query 'Parameter.Value' \
  --output text | jq .
```
**Expected**: JSON with `instance.id`, `seeder.access_key_id` (ASIA*), `seeder.principal_arn`

## CLEANUP / TEARDOWN INSTRUCTIONS

### Option 1: Delete Stack (Preserves Security Hub Findings)
```bash
# Replace <your-stack-name> with the actual stack name you used
aws cloudformation delete-stack \
  --region ${AWS::Region} \
  --stack-name <your-stack-name>
```

**What gets deleted**: VPC, EC2 instance, IAM roles, Lambda functions, EventBridge rules, SSM parameters

**What persists**: 
- Security Hub findings (must archive manually, see below)
- CloudTrail Event History (auto-expires after 90 days)
- CloudWatch Logs (retention policy configurable, default: 7 days)

### Option 2: Archive Security Hub Findings Before Deletion
```bash
# Get instance ID from stack outputs
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region ${AWS::Region} \
  --stack-name <your-stack-name> \
  --query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceId`].OutputValue' \
  --output text)

# Archive all findings matching your instance
aws securityhub batch-update-findings \
  --region ${AWS::Region} \
  --finding-identifiers Id=<finding-id>,ProductArn=<product-arn> \
  --workflow Status=RESOLVED \
  --note Text="Demo completed, archiving finding",UpdatedBy="<your-stack-name>"

# Then delete stack
aws cloudformation delete-stack \
  --region ${AWS::Region} \
  --stack-name <your-stack-name>
```

### Manual Cleanup (If Stack Deletion Fails)

1. **Disable beacon**: Use BeaconScheduleRuleName from stack outputs:
   ```bash
   BEACON_RULE=$(aws cloudformation describe-stacks \
     --region ${AWS::Region} \
     --stack-name <your-stack-name> \
     --query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
     --output text)
   aws events disable-rule --region ${AWS::Region} --name ${BEACON_RULE}
   ```
2. **Delete ENI attachments**: Secondary ENI may block instance deletion
3. **Delete VPC**: Delete NAT Gateway, VPC endpoints, then subnets, then VPC
4. **Delete IAM roles**: If roles have attached policies, detach first

## TROUBLESHOOTING

### Issue: Stack creation fails with "GuardDuty detector not found"
**Cause**: GuardDuty is not enabled in the target region  
**Fix**: Enable GuardDuty via AWS Console or CLI: `aws guardduty create-detector --enable --region ${AWS::Region}`

### Issue: Beacon Lambda shows no logs
**Cause**: Beacon schedule is disabled (default state)  
**Fix**: Enable schedule: `aws events enable-rule --name <BeaconScheduleRuleName from stack outputs> --region ${AWS::Region}`

### Issue: Security Hub findings not appearing
**Cause 1**: Beacon hasn't run yet (runs every 3 minutes)  
**Fix**: Wait 3 minutes, check beacon logs  
**Cause 2**: Security Hub CSPM not enabled  
**Fix**: Check Security Hub console, re-run custom resource

### Issue: CloudTrail seeding Lambda times out
**Cause**: Lambda in VPC without internet access, can't reach EC2 API  
**Fix**: Ensure VPC has VPC endpoints for EC2 (should be in template)

### Issue: Two users' findings are indistinguishable
**Cause**: Findings don't include user identifier in filterable field  
**Fix**: Filter by `ResourceId` (instance ARN) which includes unique instance ID per stack

### Issue: Stack deletion fails on VPC
**Cause**: ENI from EC2 instance still attached  
**Fix**: Manually detach secondary ENI, then retry stack deletion

## FAILURE RECOVERY

### Partial Stack Creation Failure

If stack creation fails partway (e.g., `CREATE_FAILED` state):

1. **Review CloudFormation events**: Identify which resource failed
2. **Delete stack**: `aws cloudformation delete-stack --stack-name cryptomining-demo-${USER}`
3. **Fix root cause** (e.g., increase EC2 instance quota, fix IAM permissions)
4. **Redeploy**: Stack is idempotent, safe to redeploy after deletion

### Stack Update Failures

CloudFormation updates are **not recommended** for this demo. If parameters change:
1. Delete existing stack
2. Deploy new stack with updated parameters

**Why**: Custom resources (GuardDuty lookup, CloudTrail seeding) may not behave correctly on UPDATE events.

## STACK DEPENDENCY ORDERING

This is a **single CloudFormation template** with internal dependencies managed by `DependsOn`:

1. **VPC resources** (VPC, subnets, route tables) - no dependencies
2. **Security Hub custom resource** - depends on VPC (for Lambda execution)
3. **GuardDuty detector lookup custom resource** - no dependencies
4. **IAM seeder role** - no dependencies
5. **EC2 instance + secondary ENI** - depends on VPC, subnets
6. **CloudTrail seeding custom resource** - depends on seeder role, EC2 instance
7. **SSM manifest parameter** - depends on CloudTrail seeding (to capture access key)
8. **Beacon Lambda** - depends on GuardDuty detector lookup, EC2 instance, SSM parameter
9. **Beacon schedule** - depends on Beacon Lambda

**No nested stacks** or external dependencies.

## OUTPUT

Provide:
1. **Complete CloudFormation template** (YAML format) - **no parameters required, fully automatic**
2. **Inline Python code for identity detector custom resource** (calls `sts:GetCallerIdentity`, parses ARN, sanitizes)
3. **Inline Python code for beacon Lambda** (embedded in template via `ZipFile`)
4. **Inline Python code for Security Hub enablement custom resource**
5. **Inline Python code for GuardDuty detector lookup custom resource**
6. **Inline Python code for CloudTrail seeding custom resource**
7. **README.md** with deployment instructions (one command: `aws cloudformation create-stack`), verification steps, and troubleshooting guide

All code must be deterministic and production-ready. Include comprehensive error handling, logging, and comments.
