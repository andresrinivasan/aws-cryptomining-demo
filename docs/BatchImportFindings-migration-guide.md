# BatchImportFindings Migration Guide

**Context:** Instructions for switching from GuardDuty's `CreateSampleFindings` to Security Hub's `BatchImportFindings` for synthetic finding generation.

**Frame:** This is for a demo in owned scratch accounts. The finding is a **synthetic Security Hub record** for detection-and-response drills. Nothing executes on hosts, no traffic is generated, and nothing leaves the account. The purpose is that the detection pipeline (event patterns, API destinations, workflows) behaves as it would against genuine findings.

---

## Why Switch from CreateSampleFindings

`guardduty:CreateSampleFindings` has critical limitations for multi-step scenarios:

| Limitation | Impact |
| --- | --- |
| `Sample: true` flag | Finding reads as a drill, not a genuine detection |
| Fabricated resource IDs | `GeneratedFindingInstanceId`, `GeneratedFindingAccessKeyId` |
| Containment impossible | Cannot quarantine, snapshot, or policy-deny fake resources |
| Detector dependency | Requires GuardDuty detector in every account |

**Use CreateSampleFindings only for:** Initial pipeline validation (EventBridge wiring, webhook delivery).

**Switch to BatchImportFindings for:** Graded scenarios where teams act on real resources.

---

## CloudFormation Implementation Notes

When implementing `BatchImportFindings` in CloudFormation with inline Lambda functions:

**Key differences from standalone Python:**
- Finding template must be **constructed in-memory** (no separate JSON file)
- Use CloudFormation intrinsic functions for dynamic values: `!Ref AWS::AccountId`, `!Ref AWS::Region`
- Pass instance metadata via **Lambda environment variables**, not SSM queries or runtime lookups
- Lambda timeout must account for Security Hub propagation delays (60s minimum)

**Resource dependencies:**
```yaml
BeaconLambda:
  Type: AWS::Lambda::Function
  DependsOn:
    - GuardDutyDetectorLookup
    - SimulatedInstance
    - SecurityHubEnabler
```

Security Hub must be enabled **before** the first import, or you get `InvalidAccessException`.

**Permissions required:**
```yaml
BeaconLambdaRole:
  Type: AWS::IAM::Role
  Properties:
    Policies:
      - PolicyName: BeaconPermissions
        PolicyDocument:
          Statement:
            - Effect: Allow
              Action:
                - securityhub:BatchImportFindings
                - securityhub:BatchUpdateFindings
                - securityhub:GetFindings
              Resource: '*'
```

**CloudFormation vs. standalone script:**

| Aspect | Standalone Script | CloudFormation Lambda |
| --- | --- | --- |
| Instance provisioning | Script calls `ec2.run_instances()` | Instance exists as stack resource |
| Metadata discovery | Runtime `DescribeInstances` | Environment variables from `!Ref`, `!GetAtt` |
| Finding template | Load from JSON file | Construct in Python code |
| Region/account | boto3 client defaults or explicit | `!Ref AWS::Region`, `!Ref AWS::AccountId` |
| Beacon state | N/A (manual script) | Parameter-controlled via EventBridge rule state |

---

## The BatchImportFindings Approach

### Mechanism

**Product ARN format:** Use the account's own product **generated from CloudFormation intrinsics**:

```yaml
BeaconLambda:
  Type: AWS::Lambda::Function
  Properties:
    Environment:
      Variables:
        PRODUCT_ARN: !Sub 'arn:aws:securityhub:${AWS::Region}:${AWS::AccountId}:product/${AWS::AccountId}/default'
```

**Important:** This product ARN is automatically created when Security Hub is enabled. No manual registration required in the Security Hub console.

Security Hub generates a genuine `Security Hub Findings - Imported` event on the default EventBridge bus. **Only the finding body is yours; the delivery is real AWS.** This means:
- Teams' EventBridge patterns work unchanged
- `BatchUpdateFindings` write-backs are indistinguishable from production
- No `events:PutEvents` tricks needed (and `source: aws.guardduty` is blocked anyway)

### Four Key Behaviors (Measured 2026-09-03)

| # | Question | Answer |
| --- | --- | --- |
| 1 | Do `aws/guardduty/*` `ProductFields` keys survive? | **Yes, verbatim** — the namespace is documented as reserved but not enforced |
| 2 | Do `ProductName: GuardDuty` / `CompanyName: Amazon` stick? | **Yes** — existing filters match with no changes |
| 3 | Does custom-product import emit `Security Hub Findings - Imported`? | **Yes**, ~15s after import, normal envelope |
| 4 | Does ARCHIVED→ACTIVE reset `Workflow.Status` to `NEW`? | **Yes** — clean re-arm without rule disable/enable |

---

## Template Construction Rules

### Start from a capture

Run `CreateSampleFindings` **once** to get the schema, then template it:

```bash
DETECTOR_ID=$(aws guardduty list-detectors --region us-west-1 --query 'DetectorIds[0]' --output text)

aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS' \
  --region us-west-1

# Wait ~20s for Security Hub import
aws securityhub get-findings \
  --filters '{"ProductName": [{"Value": "GuardDuty", "Comparison": "EQUALS"}], "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}' \
  --region us-west-1 \
  --query 'Findings[0]' > guardduty-finding-template.json
```

### Fields to SET (copy from capture)

- `SchemaVersion` — always `"2018-10-08"`
- `Id` — **must be stable** across re-fires or each import creates a new finding
- `ProductArn` — your custom product: `arn:aws:securityhub:region:account:product/account/default`
- `ProductName: "GuardDuty"` and `CompanyName: "Amazon"` — makes filters match
- `GeneratorId` — `arn:aws:guardduty:region:account:detector/<detector-id>/finding-type/<finding-type>`
- `AwsAccountId`, `Region`
- `Types` — **both entries**: `["TTPs/Command and Control/CryptoMining", "Effects/Resource Consumption/CryptoMining"]`
- `CreatedAt`, `FirstObservedAt`, `UpdatedAt`, `LastObservedAt` — ISO 8601 timestamps
- `Severity` — `{"Label": "HIGH", "Normalized": 50, "Product": 8}`
- `Title`, `Description`, `SourceUrl`
- `Action` — **critical, easy to overlook**: `{ActionType: "DNS_REQUEST", DnsRequestAction: {Protocol, Domain, Blocked}}`
- `ProductFields` — the 37-key `aws/guardduty/*` namespace block
- `Resources[0]` — **replace fake IDs with real ones** (see below)
- `RecordState: "ACTIVE"`

### Fields to NEVER SET (Security Hub generates these)

- `ProductFields["aws/securityhub/FindingId"]`
- `ProductFields["aws/securityhub/ProductName"]` / `["aws/securityhub/CompanyName"]`
- `AwsAccountName`, `ProcessedAt`, `WorkflowState`
- `Workflow` — unsettable on import; defaults to `NEW` (what you want)
- `FindingProviderFields` — **actively harmful**; causes severity recomputation (50→70)
- `Sample` — **omit it entirely**; absence is what makes it read as real

### The Queried Domain Must Not Be Real

`Action.DnsRequestAction.Domain` appears three times in the finding. Use:
- RFC 2606 reserved names: `.invalid` or `.test` (e.g., `pool-eu1.xmr-mining.invalid`)
- A domain you own
- **Never** a real mining pool — teams look this up; don't send traffic to third parties

AWS's own samples use `GeneratedFindingDomainName` for this reason.

### ProductFields Budget: 50 pairs

The real finding has **40** keys (37 set by you + 3 added by Security Hub). This leaves **10 pairs of headroom**. If you need more room, delete the `aws/guardduty/service/evidence/threatIntelligenceDetails.N_/*` block (20 keys for N=0..3).

---

## Replacing Fake Resources with Real Ones

The whole point of `BatchImportFindings` is **real resource IDs**. For `CryptoCurrency:EC2/BitcoinTool.B!DNS`:

### Resources[0] Structure

```json
{
  "Type": "AwsEc2Instance",
  "Id": "arn:aws:ec2:us-west-1:306378194054:instance/i-0abcd1234efgh5678",
  "Partition": "aws",
  "Region": "us-west-1",
  "Details": {
    "AwsEc2Instance": {
      "Type": "t3.small",
      "ImageId": "ami-0abcdef1234567890",
      "IpV4Addresses": ["10.0.1.50", "54.183.123.45"],
      "VpcId": "vpc-0123456789abcdef0",
      "SubnetId": "subnet-0abcdef1234567890",
      "LaunchedAt": "2026-09-03T14:22:31Z",
      "IamInstanceProfileArn": "arn:aws:iam::306378194054:instance-profile/unicorn-app-profile"
    }
  }
}
```

**Deliberately omit:** `Details.AwsEc2Instance.NetworkInterfaces` — Security Hub's ASFF conversion destroys GuardDuty's per-ENI detail. Omitting it teaches teams to pivot to `ec2:DescribeInstances`, which is the real skill.

### Populate from CloudFormation Outputs

In CloudFormation, the instance **already exists** as a persistent stack resource. Pass metadata via environment variables:

```yaml
SimulatedInstance:
  Type: AWS::EC2::Instance
  Properties:
    ImageId: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
    InstanceType: t3.nano
    SubnetId: !Ref PrivateSubnet
    IamInstanceProfile: !Ref SimulatedInstanceProfile
    # ...

BeaconLambda:
  Type: AWS::Lambda::Function
  DependsOn:
    - SimulatedInstance
    - GuardDutyDetectorLookup
    - SecurityHubEnabler
  Properties:
    Environment:
      Variables:
        INSTANCE_ID: !Ref SimulatedInstance
        INSTANCE_ARN: !Sub 'arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${SimulatedInstance}'
        INSTANCE_TYPE: 't3.nano'
        INSTANCE_PRIVATE_IP: !GetAtt SimulatedInstance.PrivateIp
        VPC_ID: !Ref DemoVPC
        SUBNET_ID: !Ref PrivateSubnet
        IMAGE_ID: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
        IAM_INSTANCE_PROFILE_ARN: !GetAtt SimulatedInstanceProfile.Arn
        DETECTOR_ID: !GetAtt GuardDutyDetectorLookup.DetectorId
        PRODUCT_ARN: !Sub 'arn:aws:securityhub:${AWS::Region}:${AWS::AccountId}:product/${AWS::AccountId}/default'
        REGION: !Ref AWS::Region
        AWS_ACCOUNT_ID: !Ref AWS::AccountId
        USER_IDENTIFIER: !GetAtt IdentityDetector.UserIdentifier
```

**Runtime lookup for LaunchedAt timestamp** (if exact timestamp needed):
```python
import boto3
ec2 = boto3.client('ec2')
instance = ec2.describe_instances(InstanceIds=[os.environ['INSTANCE_ID']])['Reservations'][0]['Instances'][0]
launched_at = instance['LaunchTime'].isoformat()
```

For the demo, using `datetime.utcnow()` as `LaunchedAt` is acceptable since the finding is synthetic.

---

## Finding Template Construction in Lambda

For inline Lambda code, construct the finding template programmatically:

```python
import json
import os
from datetime import datetime

def construct_finding_template():
    """Construct ASFF finding for CryptoCurrency:EC2/BitcoinTool.B!DNS."""
    now = datetime.utcnow().isoformat() + 'Z'
    
    # Stable ID across re-fires (same finding, not a new one each time)
    finding_id = f"arn:aws:securityhub:{os.environ['REGION']}:{os.environ['AWS_ACCOUNT_ID']}:subscription/guardduty/demo/crypto-mining-{os.environ['USER_IDENTIFIER']}"
    
    return {
        "SchemaVersion": "2018-10-08",
        "Id": finding_id,
        "ProductArn": os.environ['PRODUCT_ARN'],
        "ProductName": "GuardDuty",
        "CompanyName": "Amazon",
        "GeneratorId": f"arn:aws:guardduty:{os.environ['REGION']}:{os.environ['AWS_ACCOUNT_ID']}:detector/{os.environ['DETECTOR_ID']}/finding-type/CryptoCurrency:EC2/BitcoinTool.B!DNS",
        "AwsAccountId": os.environ['AWS_ACCOUNT_ID'],
        "Types": [
            "TTPs/Command and Control/CryptoMining",
            "Effects/Resource Consumption/CryptoMining"
        ],
        "CreatedAt": now,
        "UpdatedAt": now,
        "FirstObservedAt": now,
        "LastObservedAt": now,
        "Severity": {
            "Label": "HIGH",
            "Normalized": 50,
            "Product": 8
        },
        "Title": "Bitcoin-related domain name queried by EC2 instance",
        "Description": "EC2 instance is querying a domain name associated with Bitcoin activity.",
        "Resources": [
            {
                "Type": "AwsEc2Instance",
                "Id": os.environ['INSTANCE_ARN'],
                "Partition": "aws",
                "Region": os.environ['REGION'],
                "Details": {
                    "AwsEc2Instance": {
                        "Type": os.environ['INSTANCE_TYPE'],
                        "ImageId": os.environ['IMAGE_ID'],
                        "IpV4Addresses": [os.environ['INSTANCE_PRIVATE_IP']],
                        "VpcId": os.environ['VPC_ID'],
                        "SubnetId": os.environ['SUBNET_ID'],
                        "IamInstanceProfileArn": os.environ['IAM_INSTANCE_PROFILE_ARN'],
                        "LaunchedAt": now  # Or query from DescribeInstances for real timestamp
                    }
                }
            }
        ],
        "Action": {
            "ActionType": "DNS_REQUEST",
            "DnsRequestAction": {
                "Domain": "pool-eu1.xmr-mining.invalid",  # RFC 2606 reserved TLD
                "Protocol": "UDP",
                "Blocked": False
            }
        },
        "RecordState": "ACTIVE",
        "Region": os.environ['REGION'],
        "ProductFields": {
            # 37-key aws/guardduty/* namespace
            # Copy from CreateSampleFindings capture for your finding type
            "aws/guardduty/service/action/actionType": "DNS_REQUEST",
            "aws/guardduty/service/action/dnsRequestAction/domain": "pool-eu1.xmr-mining.invalid",
            "aws/guardduty/service/action/dnsRequestAction/protocol": "UDP",
            "aws/guardduty/service/action/dnsRequestAction/blocked": "false",
            "aws/guardduty/service/resourceRole": "TARGET",
            "aws/guardduty/service/detectorId": os.environ['DETECTOR_ID'],
            "aws/guardduty/service/serviceName": "guardduty",
            "aws/guardduty/service/additionalInfo": json.dumps({"threatListName": "BitcoinIP"}),
            # ... (remaining ProductFields from capture)
        }
    }
```

**Important considerations:**
- **Omit** `Sample`, `FindingProviderFields`, and any Security Hub-generated fields
- **Stable `Id`** ensures re-imports update the same finding instead of creating duplicates
- **RFC 2606 domain** (`.invalid` or `.test`) prevents accidental traffic to real mining pools
- **ProductFields** must be copied from a real GuardDuty sample capture for authenticity

**Inline code size limit:** CloudFormation inline Lambda code is limited to 4096 bytes. If your finding template with ProductFields exceeds this:
- Option 1: Store template in S3, Lambda downloads at runtime
- Option 2: Construct dynamically with minimal ProductFields (keep only the critical keys)
- Option 3: Package Lambda as a ZIP and upload to S3 (use `Code: { S3Bucket, S3Key }`)

---

## Event Pattern Changes Required

### Before (with CreateSampleFindings)

```json
{
  "source": ["aws.securityhub"],
  "detail-type": ["Security Hub Findings - Imported"],
  "detail": {
    "findings": {
      "ProductArn": ["arn:aws:securityhub:us-west-1::product/aws/guardduty"]
    }
  }
}
```

### After (with BatchImportFindings)

**Change:** Pin on `ProductName` instead of `ProductArn`:

```json
{
  "source": ["aws.securityhub"],
  "detail-type": ["Security Hub Findings - Imported"],
  "detail": {
    "findings": {
      "ProductName": ["GuardDuty"]
    }
  }
}
```

**Why:** Custom product ARN is `arn:...product/306378194054/default`, not `.../aws/guardduty`. `ProductName: "GuardDuty"` matches **both** real and simulated findings, so dev and production behave identically.

---

## Re-Arming for Test Loops

### The Problem

Writing `Workflow.Status = NEW` directly **re-triggers your own rule** because Security Hub re-emits the event. The team's workflow sets `NOTIFIED` again within ~20s, so the finding is never observable at `NEW`.

### The Solution: ARCHIVED → ACTIVE

```python
import boto3
import time

securityhub = boto3.client('securityhub', region_name='us-west-1')

# Step 1: Archive the finding
securityhub.batch_update_findings(
    FindingIdentifiers=[{
        'Id': 'arn:aws:securityhub:us-west-1:306378194054:subscription/aws/guardduty/...',
        'ProductArn': 'arn:aws:securityhub:us-west-1:306378194054:product/306378194054/default'
    }],
    RecordState='ARCHIVED'
)

# Step 2: Wait for consistency
time.sleep(5)

# Step 3: Re-import as ACTIVE (RecordState defaults to ACTIVE)
securityhub.batch_import_findings(Findings=[construct_finding_template()])  # Same Id, RecordState: ACTIVE
```

**Result:** Security Hub resets `Workflow.Status` to `NEW` itself. No rule disable/enable needed.

**Timing:** Archive takes ~12–35s to fully propagate; the re-import emits the event ~15s later.

**CloudFormation beacon integration:**
```python
def handler(event, context):
    """Beacon handler with auto-pause on NOTIFIED status."""
    # Check current status
    findings = securityhub.get_findings(
        Filters={
            'ProductName': [{'Value': 'GuardDuty', 'Comparison': 'EQUALS'}],
            'Type': [{'Value': 'TTPs/Command and Control/CryptoCurrency:EC2-BitcoinTool.B!DNS', 'Comparison': 'EQUALS'}],
            'ResourceId': [{'Value': os.environ['INSTANCE_ARN'], 'Comparison': 'EQUALS'}]
        },
        MaxResults=1
    )
    
    if findings['Findings']:
        workflow_status = findings['Findings'][0].get('Workflow', {}).get('Status', 'NEW')
        if workflow_status == 'NOTIFIED':
            print("Finding already NOTIFIED, beacon paused")
            return {'statusCode': 200, 'body': 'Beacon paused'}
    
    # Import finding
    response = securityhub.batch_import_findings(Findings=[construct_finding_template()])
    
    if response['FailedCount'] > 0:
        raise RuntimeError(f"Import failed: {response['FailedFindings']}")
    
    return {'statusCode': 200, 'body': 'Finding created'}
```

---

## Behaviors to Handle

### Read-After-Write is Slow

First visibility: **38.1 seconds** observed. `RecordState` and `Workflow.Status` can be transiently inconsistent.

**Implication:** Always poll, never read once. Example:

```python
import time

for attempt in range(10):
    findings = securityhub.get_findings(Filters={
        'Id': [{'Value': finding_id, 'Comparison': 'EQUALS'}]
    })['Findings']
    
    if findings and findings[0]['Workflow']['Status'] == 'NEW':
        break
    
    time.sleep(5)
```

### Partial Failure Returns HTTP 200

```python
response = securityhub.batch_import_findings(Findings=[...])

if response['FailedCount'] > 0:
    print(f"Failed: {response['FailedFindings']}")
    raise RuntimeError("Import failed")
```

### Repeat Import Updates In-Place

A second `batch-import-findings` with the same `Id` **updates** the finding, preserving `Workflow` and `Note`.

**Implication:** `Id` must be **stable across re-fires** or each beacon tick creates a new finding.

### Archived Findings Linger 30 Days

No delete API exists. Archived findings are inert to `RecordState=ACTIVE` filters but still returned by `Id`-prefix or `ProductArn` queries.

**Implication:** Namespace test findings (e.g., `Id` includes `"gameday-test-..."`) so they're recognizable.

---

## CloudFormation Implementation Diff

### BeaconLambda Code Changes

```diff
- guardduty = boto3.client('guardduty')
- guardduty.create_sample_findings(
-     DetectorId=os.environ['DETECTOR_ID'],
-     FindingTypes=['CryptoCurrency:EC2/BitcoinTool.B!DNS']
- )
+ securityhub = boto3.client('securityhub')
+ 
+ finding = construct_finding_template()  # Build from env vars
+ 
+ response = securityhub.batch_import_findings(Findings=[finding])
+ if response['FailedCount'] > 0:
+     raise RuntimeError(f"Import failed: {response['FailedFindings']}")
```

### BeaconLambdaRole Policy Changes

```diff
  BeaconLambdaRole:
    Type: AWS::IAM::Role
    Properties:
      Policies:
        - PolicyName: BeaconPermissions
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action:
-                 - guardduty:CreateSampleFindings
+                 - securityhub:BatchImportFindings
+                 - securityhub:BatchUpdateFindings
                  - securityhub:GetFindings
                Resource: '*'
```

### BeaconLambda Environment Variables

```diff
  BeaconLambda:
    Type: AWS::Lambda::Function
+   DependsOn:
+     - SimulatedInstance
+     - GuardDutyDetectorLookup
+     - SecurityHubEnabler
    Properties:
      Environment:
        Variables:
          DETECTOR_ID: !GetAtt GuardDutyDetectorLookup.DetectorId
+         PRODUCT_ARN: !Sub 'arn:aws:securityhub:${AWS::Region}:${AWS::AccountId}:product/${AWS::AccountId}/default'
          INSTANCE_ARN: !Sub 'arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${SimulatedInstance}'
+         INSTANCE_ID: !Ref SimulatedInstance
+         INSTANCE_TYPE: 't3.nano'
+         INSTANCE_PRIVATE_IP: !GetAtt SimulatedInstance.PrivateIp
+         VPC_ID: !Ref DemoVPC
+         SUBNET_ID: !Ref PrivateSubnet
+         IMAGE_ID: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
+         IAM_INSTANCE_PROFILE_ARN: !GetAtt SimulatedInstanceProfile.Arn
          REGION: !Ref AWS::Region
+         AWS_ACCOUNT_ID: !Ref AWS::AccountId
          USER_IDENTIFIER: !GetAtt IdentityDetector.UserIdentifier
```

### EventBridge Rule Pattern (unchanged from guide)

```yaml
# In EventBridge routing CloudFormation template or Tines configuration
# Change ProductArn filter to ProductName
```

### Re-Arming Logic (add to separate reset script or beacon)

```python
def reset_finding_if_notified(finding_id, product_arn):
    """Archive then re-import to reset Workflow.Status to NEW."""
    securityhub = boto3.client('securityhub')
    
    # Archive
    securityhub.batch_update_findings(
        FindingIdentifiers=[{'Id': finding_id, 'ProductArn': product_arn}],
        RecordState='ARCHIVED'
    )
    
    time.sleep(5)
    
    # Re-import with same Id will reset to NEW
    securityhub.batch_import_findings(Findings=[construct_finding_template()])
```

---

## Verification Checklist

After implementing `BatchImportFindings`:

- [ ] Finding appears in Security Hub console within 40s
- [ ] `PRODUCT_ARN` environment variable matches custom product format `arn:aws:securityhub:region:account:product/account/default`
- [ ] Lambda environment variables populated from CloudFormation intrinsics (`!Ref`, `!GetAtt`, `!Sub`)
- [ ] Instance ID in finding matches `!Ref SimulatedInstance` output
- [ ] `Sample` key is **absent** (not `false`, absent)
- [ ] `ProductName: "GuardDuty"` and `CompanyName: "Amazon"` are set
- [ ] `Workflow.Status` defaults to `NEW` on fresh import
- [ ] EventBridge rule matches (check rule metrics for `MatchedEvents`)
- [ ] Resources[0].Id points to a **real, queryable** EC2 instance
- [ ] `Action.DnsRequestAction.Domain` is `.invalid` or `.test` TLD
- [ ] Re-import with same `Id` updates (not duplicates)
- [ ] ARCHIVED→ACTIVE cycle resets `Workflow.Status` to `NEW`
- [ ] Beacon Lambda has `DependsOn: [SimulatedInstance, GuardDutyDetectorLookup, SecurityHubEnabler]`

---

## Common Pitfalls

| Mistake | Symptom | Fix |
| --- | --- | --- |
| Set `FindingProviderFields.Severity` | Severity recomputes from label (50→70) | Omit `FindingProviderFields` entirely |
| Filter on `ProductArn` for aws/guardduty | Rule never matches simulated findings | Filter on `ProductName: ["GuardDuty"]` |
| Re-arm with `BatchUpdateFindings(Status=NEW)` | Finding stays `NOTIFIED`, never resets | Use ARCHIVED→ACTIVE cycle |
| Populate `NetworkInterfaces` in Resources[0] | More detail than real CSPM conversion | Leave it absent; teams pivot to DescribeInstances |
| Real mining pool domain in `Domain` field | Teams query it, send traffic externally | Use `.invalid` or `.test` TLD |
| Different `Id` on each beacon fire | Dozens of findings accumulate | Use stable `Id` (hash of account+region+type+user) |
| Check HTTP status only | Partial failures look like success | Check `response['FailedCount']` in body |
| Lambda inline code exceeds 4KB | CloudFormation deployment fails | Externalize template to S3 or construct dynamically |
| Missing `DependsOn` in CloudFormation | Lambda runs before Security Hub enabled | Add `DependsOn: SecurityHubEnabler` |
| Hard-coded region/account in finding | Works in one account, breaks elsewhere | Use `!Sub`, `!Ref AWS::Region`, `!Ref AWS::AccountId` |
| Instance ARN mismatch | Finding references wrong instance | Use `!Sub 'arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${SimulatedInstance}'` |

---

## References

- Security Hub `BatchImportFindings` API: https://docs.aws.amazon.com/securityhub/1.0/APIReference/API_BatchImportFindings.html
- ASFF schema: https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html
- GuardDuty finding types: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-ec2.html
- CloudFormation Lambda functions: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-lambda-function.html
- CloudFormation intrinsic functions: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference.html

---

**Final note:** This is for training scenarios in owned scratch accounts. Never use synthetic findings in production monitoring pipelines.

**CloudFormation Deployment:** When implementing in CloudFormation, the beacon Lambda should be deployed with `State: DISABLED` by default (via parameter) to prevent accidental finding generation during stack creation. Enable via parameter update or EventBridge rule state change:

```yaml
Parameters:
  BeaconEnabled:
    Type: String
    Default: DISABLED
    AllowedValues:
      - ENABLED
      - DISABLED

Resources:
  BeaconScheduleRule:
    Type: AWS::Events::Rule
    Properties:
      ScheduleExpression: 'rate(3 minutes)'
      State: !Ref BeaconEnabled  # Controlled by parameter
```
