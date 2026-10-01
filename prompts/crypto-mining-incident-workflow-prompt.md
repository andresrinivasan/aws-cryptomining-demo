# Crypto-Mining Incident Response Workflow

Build a Tines 3B workflow that handles cryptocurrency mining detection and response for AWS GameDay.

## Required Parameters
- **Workflow Name**: `Crypto-Mining Incident Response`
- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]

## Workflow Structure

### Trigger
1. Create a webhook trigger step that receives Security Hub findings in EventBridge format

### Task 1: Ingest & Enrich
2. Parse the Security Hub finding to extract:
   - Instance ID from `Resources[0].Id` (format: `arn:aws:ec2:region:account:instance/i-xxxxx`)
   - Finding type, severity, first/last observed times

3. Query CloudTrail for the intrusion breadcrumb:
   - Use `cloudtrail:LookupEvents` with filter: `EventName=RunInstances`
   - Search recent events (last 24 hours) and find entries with temporary credentials
   - Extract the access key ID (ASIA* format) from the event's `userIdentity.accessKeyId`
   - Extract the assumed role ARN from `userIdentity.arn` (this is the seeder role)

4. Discover the instance's network interfaces:
   - Call `ec2:DescribeNetworkInterfaces` with filter: `attachment.instance-id = {instance-id}`
   - Extract all attached ENI IDs (will include both eth0 and eth1)

5. Update Security Hub finding status:
   - Call `securityhub:BatchUpdateFindings` to set `Workflow.Status = "NOTIFIED"`
   - Add a note: `"Tines workflow received finding at {timestamp}"`

### Task 2: Network Containment
6. Create a deny-all security group:
   - Call `ec2:CreateSecurityGroup` with name `cryptomining-quarantine-{instance-id}`
   - Description: "Emergency quarantine for crypto-mining incident"
   - No inbound or outbound rules (deny-all by default)

7. Attach security group to all ENIs:
   - For each ENI ID discovered in step 4:
     - Call `ec2:ModifyNetworkInterfaceAttribute` to set `Groups = [quarantine-sg-id]`

### Task 3: Credential Revocation
8. Attach a deny-all IAM policy to the seeder role:
   - Use the role ARN discovered from CloudTrail in step 3
   - Create an inline policy named `EmergencyRevocation` with:
     ```json
     {
       "Version": "2012-10-17",
       "Statement": [{
         "Effect": "Deny",
         "Action": "*",
         "Resource": "*"
       }]
     }
     ```
   - Call `iam:PutRolePolicy` to attach it

### Testing Step
9. Create a separate testing step (not connected to the main flow):
   - Name: "Post Sample Finding"
   - Action: Send a POST request to the webhook URL with a realistic Security Hub ASFF payload
   - Payload structure:
     ```json
     {
       "version": "0",
       "id": "sample-event-id",
       "detail-type": "Security Hub Findings - Imported",
       "source": "aws.securityhub",
       "account": "[account-id]",
       "time": "[ISO-8601-timestamp]",
       "region": "[region]",
       "resources": ["arn:aws:securityhub:[region]:[account]:subscription/aws-foundational-security-best-practices/v/1.0.0"],
       "detail": {
         "findings": [{
           "SchemaVersion": "2018-10-08",
           "Id": "arn:aws:guardduty:[region]:[account]:detector/[detector-id]/finding/[finding-id]",
           "ProductArn": "arn:aws:securityhub:[region]::product/aws/guardduty",
           "ProductName": "GuardDuty",
           "AwsAccountId": "[account-id]",
           "Types": ["TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS"],
           "FirstObservedAt": "[ISO-8601-timestamp]",
           "LastObservedAt": "[ISO-8601-timestamp]",
           "Severity": {
             "Label": "HIGH",
             "Normalized": 70
           },
           "Title": "EC2 instance is querying a domain name associated with cryptocurrency mining activity",
           "Description": "EC2 instance i-xxxxx is querying a domain name associated with Bitcoin mining activity.",
           "Resources": [{
             "Type": "AwsEc2Instance",
             "Id": "arn:aws:ec2:[region]:[account]:instance/i-xxxxx",
             "Partition": "aws",
             "Region": "[region]"
           }],
           "Workflow": {
             "Status": "NEW"
           },
           "RecordState": "ACTIVE"
         }]
       }
     }
     ```

## Expected Behavior
- Webhook receives finding → enriches with CloudTrail + EC2 data → updates Security Hub → isolates network → revokes credentials
- Each task should log its actions for audit trail
- The testing step can be run manually to verify the workflow without deploying EventBridge routing

Build this workflow now.
