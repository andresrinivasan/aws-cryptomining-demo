# Infrastructure prompt

You are setting up AWS infrastructure for a AWS and Tines 3Bdemo. The exercise simulates a cryptocurrency mining attack detected by GuardDuty with an intelligent workflow implemented in Tines 3B.

## CONTEXT

1. This is a demo in accounts Tines owns
2. GuardDuty findings are Security Hub *records*, not actual attacks
3. Nothing executes on hosts, no traffic generated, no real domains contacted

## EXPECTATIONS

1. All resources must be tagged with a user tag. The value is the IAM user email address of who is invoking this prompt
2. This needs to be repeatable. You are using CloudFormation, custom resources, and scripts to set up the infrastructure.
3. Do not make assumptions on where the templates are being deployed. Ensure that all deployments are region-agnostic and can be applied to any account within the organization. Use CloudFormation parameters and references to dynamically resolve regions and account IDs.
4. For resources that are created, use the prefix cryptomining-demo- and append the IAM user email. If the resource can't be named, use a tag called name and this value.

## SETUP REQUIREMENTS

1. ENABLE SECURITY HUB CSPM
   - Run: aws securityhub enable-security-hub --no-enable-default-standards
   - Verify GuardDuty product integration auto-enabled
   - DO NOT enable FSBP/CIS standards (generates thousands of control findings + AWS Config costs)

2. CREATE BEACON LAMBDA
   - Function: Python 3.14, runs a script to create sample GuardDuty findings (the beacon)
   - Schedule: rate(3 minutes) via EventBridge rule BeaconSchedule
   - Purpose: Calls guardduty:CreateSampleFindings with type CryptoCurrency:EC2/BitcoinTool.B!DNS, checks if finding still at Workflow.Status=NEW (stops when NOTIFIED)
   - IAM permissions: guardduty:CreateSampleFindings, securityhub:GetFindings
   - Environment variables: DETECTOR_ID, PRODUCT_ARN, INSTANCE_ARN, REGION

3. CREATE API DESTINATION INVOKE ROLE
   - Service principal: events.cryptomining.amazonaws.com
   - Policy: events:InvokeApiDestination on resource api-destination/* (wildcard because destination ARN unknown at stack creation)
   - Export ARN as CloudFormation output: ApiDestinationInvokeRoleArn

4. SEED SIMULATION RESOURCES
   - EC2 instance: t3.nano in us-west-1 with TWO network interfaces (eth0 + eth1)
   - IAM seeder principal: Role cryptomining-ci-deploy with access key. The seeder is an IAM role, not a user. It uses temporary session credentials (ASIA prefix) from sts:AssumeRole.
   - The GuardDuty detector ID will need to be discovered and referenced in the beacon Lambda environment variables
   - SSM Parameter: /cryptomining-sim/manifest with JSON containing: {instance_id, eni_ids[], volume_ids[], seeder_arn, access_key_id}
   - Seed CloudTrail: Call ec2:RunInstances via seeder principal so access key appears in CloudTrail userIdentity.accessKeyId

5. CONFIRM CLOUDTRAIL LOGGING
   - Organization trail must capture management events (RunInstances, CreateSecurityGroup, PutRolePolicy)
   - Verify: aws cloudtrail lookup-events AttributeKey=EventName,AttributeValue=RunInstances --max-results 1

## CONSTRAINTS

- AWS Organizations SCP blocks iam:CreateUser and iam:CreateAccessKey (use existing users or roles)
- Security Hub finding type transforms from CryptoCurrency:EC2/BitcoinTool.B!DNS → TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS (slash becomes dash in ASFF)
- Beacon schedule state defaults to ENABLED on every stack update; must manually disable between test runs

## VERIFICATION

- Beacon fires every 3 minutes: aws logs tail /aws/lambda/gdQuests-*-BeaconLambda-* --follow
- Finding appears in Security Hub: aws securityhub get-findings --filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],"Type":[{"Value":"TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS","Comparison":"EQUALS"}]}'
- CloudTrail breadcrumbs exist: aws cloudtrail lookup-events --lookup-attributes AttributeKey=AccessKeyId,AttributeValue=<AKIA...>

## OUTPUT

Provide the exact CloudFormation template and beacon Lambda code to deploy this infrastructure. Include resource tagging, IAM least-privilege policies, environment variable configuration, and documentation.
