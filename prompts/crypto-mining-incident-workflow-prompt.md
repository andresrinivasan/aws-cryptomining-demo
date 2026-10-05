# Crypto-Mining Incident Response Workflow

Build a Tines 3B workflow that responds to cryptocurrency mining detections from GuardDuty.

## Required Parameters

- **Workflow Name**: `Crypto-Mining Incident Response`
- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]

## Scenario

GuardDuty has detected a bitcoin mining finding in your AWS environment. The finding is available in Security Hub.

## Phase 1: Investigation (Do This First)

Before building the workflow, investigate the finding manually to understand what happened:

- Examine the Security Hub finding - what resource is involved?
- Query CloudTrail - how was this resource created? What credentials were used?
- Inspect EC2 - what network interfaces and security groups exist?
- Identify the attack vector - was it temporary credentials (assumed role) or long-term keys?

Use AWS CLI or Console to answer these questions. Understand the full attack chain.

## Phase 2: Build Response Workflow

Now that you understand what happened, build a Tines workflow that automates the response:

**Input**: Security Hub finding (via webhook from EventBridge)

**Response Actions** (based on what you discovered):

- Update Security Hub to mark the finding as under investigation
- Isolate the compromised resource by cutting off network access
- Revoke the credentials that were compromised

**Testing**: Include a test step that can post a sample finding into your workflow so you can test the response flow from the Tines editor.

