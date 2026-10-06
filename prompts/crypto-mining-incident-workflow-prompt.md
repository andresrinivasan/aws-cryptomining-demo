# Crypto-Mining Incident Response Workflow

Build a Tines 3B workflow that responds to cryptocurrency mining detections from GuardDuty.

## Required Parameters

- **Workflow Name**: `Crypto-Mining Incident Response`
- **AWS Region**: [USER PROVIDES - e.g., `us-west-1`]
- **Tines 3B Space**: [USER PROVIDES]

## Scenario

GuardDuty has detected a bitcoin mining finding in your AWS environment. The finding is available in Security Hub.

## Phase 1: Investigation (Do This First)

Before building the workflow, investigate the finding manually to understand what happened. Start from the finding and follow the evidence outward - each answer should point you to the next question:

- Examine the Security Hub finding - what resource is involved, and how is it identified?
- Query CloudTrail - how was this resource created? What credentials were used, and what do those credentials tell you about the actor?
- Inspect EC2 - what network interfaces and security groups exist?
- Identify the attack vector - what kind of credentials were used, and what would it take to neutralize them?

Use AWS CLI or Console to answer these questions. Work only from what the finding and live AWS queries reveal - do not rely on prior knowledge of how the environment was set up. Understand the full attack chain.

You will use this investigation to build a response workflow that deterministically investigates and takes action from the finding alone. Do not hardcode any specifics into the workflow.

## Phase 2: Build Response Workflow

Now that you understand what happened, build a Tines workflow that investigates and automates the response. 

Create the top level README file to document the workflow and its usage first. As you create the steps, create the step README. You may need to go back and update the top level README. 

**Input**: Security Hub finding (via webhook from EventBridge)

**Response Actions** (based on what is discovered from the first steps int the workflow):

- Update Security Hub to mark the finding as under investigation
- Isolate the compromised resource by swapping its network access to a dedicated isolation security group (the resting state may already restrict traffic, so isolation must be an observable change in posture)
- Neutralize the credentials that were compromised, using whatever mechanism is appropriate for the kind of credentials you identified

Derive every target (the resource to isolate, the credentials to neutralize) from the incoming finding and live AWS queries at runtime - do not hardcode values from this specific incident. The workflow is built against the current finding but must handle similar future incidents automatically.

**Testing**: Include a test step that can post a sample finding into your workflow so you can test the response flow from Tines 3B.

