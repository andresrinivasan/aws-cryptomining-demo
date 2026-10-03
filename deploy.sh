#!/usr/bin/env bash
set -euo pipefail

# AWS Cryptomining Demo - Deployment Script
# Deploys the CloudFormation stack with sensible defaults

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AWS_REGION="${AWS_REGION:-us-west-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
STACK_NAME="${STACK_NAME:-cryptomining-demo-$(whoami)}"
ENABLE_BEACON=false
RUN_VERIFY=false
BEACON_ENABLED_PARAM="DISABLED"

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy the AWS Cryptomining Demo infrastructure.

OPTIONS:
    --region REGION         AWS region (default: ${AWS_REGION})
    --profile PROFILE       AWS profile to use (default: ${AWS_PROFILE:-none})
    --stack-name NAME       CloudFormation stack name (default: ${STACK_NAME})
    --enable-beacon         Enable beacon schedule after deployment
    --beacon-enabled        Deploy with beacon already enabled (default: disabled)
    --verify               Run verification checks after deployment
    -h, --help             Show this help message

EXAMPLES:
    # Quick deploy with defaults
    $0

    # Deploy with specific AWS profile
    $0 --profile sandbox

    # Custom region and stack name
    $0 --region us-east-1 --stack-name my-demo

    # Deploy and enable beacon
    $0 --enable-beacon

    # Deploy with beacon enabled and verify
    $0 --beacon-enabled --verify

ENVIRONMENT VARIABLES:
    AWS_REGION             Default AWS region (overridden by --region)
    AWS_PROFILE            Default AWS profile (overridden by --profile)
    STACK_NAME             Default stack name (overridden by --stack-name)

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --enable-beacon)
            ENABLE_BEACON=true
            shift
            ;;
        --beacon-enabled)
            BEACON_ENABLED_PARAM="ENABLED"
            shift
            ;;
        --verify)
            RUN_VERIFY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# Set up profile argument for AWS CLI commands
if [[ -n "$AWS_PROFILE" ]]; then
    PROFILE_ARG="--profile $AWS_PROFILE"
else
    PROFILE_ARG=""
fi

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found. Please install it first.${NC}"
    exit 1
fi

if ! aws $PROFILE_ARG sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or invalid.${NC}"
    exit 1
fi

if ! aws $PROFILE_ARG guardduty list-detectors --region "$AWS_REGION" --query 'DetectorIds[0]' --output text | grep -q '^[a-z0-9]'; then
    echo -e "${YELLOW}Warning: GuardDuty does not appear to be enabled in ${AWS_REGION}.${NC}"
    echo -e "${YELLOW}This deployment will fail. Enable it with:${NC}"
    echo -e "  aws $PROFILE_ARG guardduty create-detector --enable --region ${AWS_REGION}"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [[ ! -f "cryptomining-demo-stack.yaml" ]]; then
    echo -e "${RED}Error: cryptomining-demo-stack.yaml not found in current directory.${NC}"
    exit 1
fi

# Display deployment info
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  AWS Cryptomining Demo - Deployment${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "Region:        ${GREEN}${AWS_REGION}${NC}"
echo -e "Stack Name:    ${GREEN}${STACK_NAME}${NC}"
echo -e "Beacon:        ${GREEN}${BEACON_ENABLED_PARAM}${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

# Deploy the stack
echo -e "${BLUE}Deploying CloudFormation stack...${NC}"
aws $PROFILE_ARG cloudformation create-stack \
    --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" \
    --template-body file://cryptomining-demo-stack.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=BeaconEnabled,ParameterValue="$BEACON_ENABLED_PARAM" \
    --tags Key=Project,Value=CryptominingDemo Key=ManagedBy,Value=deploy-script

echo -e "${GREEN}✓ Stack creation initiated${NC}"
echo

# Wait for stack creation
echo -e "${BLUE}Waiting for stack creation to complete (5-8 minutes)...${NC}"
echo -e "${YELLOW}Tip: Press Ctrl+C to stop waiting (stack will continue deploying)${NC}"
echo

if aws $PROFILE_ARG cloudformation wait stack-create-complete \
    --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ Stack created successfully!${NC}"
else
    echo -e "${RED}✗ Stack creation failed or was interrupted${NC}"
    echo -e "${YELLOW}Check status with:${NC}"
    echo -e "  aws $PROFILE_ARG cloudformation describe-stack-events --region $AWS_REGION --stack-name $STACK_NAME"
    exit 1
fi

echo

# Show stack outputs
echo -e "${BLUE}Stack Outputs:${NC}"
aws $PROFILE_ARG cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
    --output table

echo

# Enable beacon if requested
if [[ "$ENABLE_BEACON" == true ]]; then
    echo -e "${BLUE}Enabling beacon schedule...${NC}"

    BEACON_RULE=$(aws $PROFILE_ARG cloudformation describe-stacks \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
        --output text)

    aws $PROFILE_ARG events enable-rule --region "$AWS_REGION" --name "$BEACON_RULE"
    echo -e "${GREEN}✓ Beacon enabled (first invocation in 3 minutes)${NC}"
    echo
fi

# Run verification if requested
if [[ "$RUN_VERIFY" == true ]]; then
    echo -e "${BLUE}Running verification checks...${NC}"
    echo

    USER_ID=$(aws $PROFILE_ARG cloudformation describe-stacks \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`UserIdentifier`].OutputValue' \
        --output text)

    echo -e "${BLUE}1. Checking SSM manifest parameter...${NC}"
    if aws $PROFILE_ARG ssm get-parameter \
        --region "$AWS_REGION" \
        --name "/cryptomining-demo/${USER_ID}/manifest" \
        --query 'Parameter.Value' \
        --output text | jq -e '.version == 1' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ SSM manifest parameter exists${NC}"
    else
        echo -e "${RED}✗ SSM manifest parameter not found or invalid${NC}"
    fi

    echo -e "${BLUE}2. Checking CloudTrail seeding...${NC}"
    if aws $PROFILE_ARG cloudtrail lookup-events \
        --region "$AWS_REGION" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
        --max-results 10 \
        --query 'Events[].[EventTime,Username]' \
        --output text | grep -q 'ASIA'; then
        echo -e "${GREEN}✓ CloudTrail seeding successful (ASIA* credentials found)${NC}"
    else
        echo -e "${YELLOW}⚠ CloudTrail seeding may not have completed yet${NC}"
    fi

    echo -e "${BLUE}3. Checking VPC and instance...${NC}"
    INSTANCE_ID=$(aws $PROFILE_ARG cloudformation describe-stacks \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceId`].OutputValue' \
        --output text)

    INSTANCE_STATE=$(aws $PROFILE_ARG ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    if [[ "$INSTANCE_STATE" == "running" ]]; then
        echo -e "${GREEN}✓ EC2 instance is running${NC}"
    else
        echo -e "${YELLOW}⚠ EC2 instance state: ${INSTANCE_STATE}${NC}"
    fi

    echo
fi

# Success message
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo

echo -e "${BLUE}Next Steps:${NC}"
echo

if [[ "$ENABLE_BEACON" == false ]] && [[ "$BEACON_ENABLED_PARAM" == "DISABLED" ]]; then
    echo -e "1. Enable beacon to start generating findings:"
    echo -e "   ${YELLOW}make enable-beacon${NC}"
    echo
fi

echo -e "2. Build the Tines workflow:"
echo -e "   Follow ${YELLOW}prompts/crypto-mining-incident-workflow-prompt.md${NC}"
echo

echo -e "3. Configure EventBridge routing:"
echo -e "   Follow ${YELLOW}prompts/eventbridge-routing-prompt.md${NC}"
echo

echo -e "${BLUE}Useful Commands:${NC}"
echo -e "  ${YELLOW}make logs${NC}         - Tail beacon Lambda logs"
echo -e "  ${YELLOW}make verify${NC}       - Run verification checks"
echo -e "  ${YELLOW}make outputs${NC}      - Show stack outputs"
echo -e "  ${YELLOW}make clean${NC}        - Delete the stack"
echo
