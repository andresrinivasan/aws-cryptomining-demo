#!/usr/bin/env bash
set -euo pipefail

# AWS Cryptomining Demo - Reset Script
#
# Reverts the live-state changes made by the Tines incident-response workflow
# so the demo can be run again WITHOUT undeploy/redeploy.
#
# The workflow makes three runtime mutations, all derived from the finding:
#   1. Security Hub finding Workflow.Status -> NOTIFIED (and the beacon pauses)
#   2. Instance ENIs swapped onto a dedicated isolation security group
#   3. The compromised seeder-role credentials neutralized (inline deny policy,
#      managed policy attach, or a session-revocation policy)
#
# This script DISCOVERS each of those mutations at runtime rather than assuming
# a fixed implementation, then inverts them:
#   1. Resets the finding Workflow.Status back to NEW (re-arms the beacon)
#   2. Rebinds every instance ENI back to the stack's original instance SG
#   3. Strips anything on the seeder role beyond its deployed baseline
#      (baseline = one inline policy "CloudTrailSeeding", zero attached managed)
#   4. Best-effort deletes orphaned isolation SGs the workflow created
#
# Nothing is hardcoded from a specific incident: the original instance SG, the
# instance id, and the seeder role are read from the live CloudFormation stack
# outputs; the isolation SG and neutralization mechanism are discovered live.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AWS_REGION="${AWS_REGION:-us-west-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
STACK_NAME="${STACK_NAME:-cryptomining-demo-$(whoami)}"
DELETE_ISOLATION_SG=true
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Reset the live AWS state changed by the incident-response workflow so the demo
can be re-run without redeploying the stack.

OPTIONS:
    --region REGION        AWS region (default: ${AWS_REGION})
    --profile PROFILE      AWS profile to use (default: ${AWS_PROFILE:-none})
    --stack-name NAME      CloudFormation stack name (default: ${STACK_NAME})
    --keep-isolation-sg    Do not delete orphaned isolation security groups
    --dry-run              Show what would change without mutating anything
    -h, --help             Show this help message

ENVIRONMENT VARIABLES:
    AWS_REGION, AWS_PROFILE, STACK_NAME  (same meaning as the flags above)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --region) AWS_REGION="$2"; shift 2 ;;
        --profile) AWS_PROFILE="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; shift 2 ;;
        --keep-isolation-sg) DELETE_ISOLATION_SG=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Error: Unknown option $1${NC}"; echo "Run '$0 --help' for usage."; exit 1 ;;
    esac
done

if [[ -n "$AWS_PROFILE" ]]; then
    PROFILE_ARG="--profile $AWS_PROFILE"
else
    PROFILE_ARG=""
fi

# aws wrapper: injects region + profile on every call
aws_() { aws $PROFILE_ARG --region "$AWS_REGION" "$@"; }

# run <description> <cmd...> : respects --dry-run
run() {
    local desc="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "   ${YELLOW}[dry-run]${NC} would $desc"
        return 0
    fi
    "$@"
}

echo -e "${BLUE}Checking prerequisites...${NC}"
command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: AWS CLI not found.${NC}"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo -e "${RED}Error: jq not found.${NC}"; exit 1; }
aws_ sts get-caller-identity >/dev/null 2>&1 || { echo -e "${RED}Error: AWS credentials not configured or invalid.${NC}"; exit 1; }

echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  AWS Cryptomining Demo - Reset${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "Region:        ${GREEN}${AWS_REGION}${NC}"
echo -e "Stack Name:    ${GREEN}${STACK_NAME}${NC}"
[[ "$DRY_RUN" == true ]] && echo -e "Mode:          ${YELLOW}DRY RUN (no changes)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

# ---------------------------------------------------------------------------
# Discover ground truth from the stack (resting state source of truth)
# ---------------------------------------------------------------------------
echo -e "${BLUE}Discovering stack resources...${NC}"

output() {
    aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

if ! aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    echo -e "${RED}Error: stack '$STACK_NAME' not found in ${AWS_REGION}.${NC}"
    echo -e "${YELLOW}Reset operates on a deployed stack. Deploy first, or pass --stack-name/--region.${NC}"
    exit 1
fi

INSTANCE_ID=$(output SimulatedInstanceId)
INSTANCE_ARN=$(output SimulatedInstanceArn)
SEEDER_ROLE_ARN=$(output SeederRoleArn)
USER_ID=$(output UserIdentifier)
VPC_ID=$(output VpcId)

# Seeder role name: last path segment of the ARN
SEEDER_ROLE_NAME="${SEEDER_ROLE_ARN##*/}"

# Original instance security group: the stack-created deny-all SG. Discover it
# by its stack tag/name rather than hardcoding an id.
ORIGINAL_SG_ID=$(aws_ ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=tag:Name,Values=cryptomining-demo-${USER_ID}-instance-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo -e "${RED}Error: could not resolve instance id from stack outputs.${NC}"; exit 1
fi
if [[ -z "$ORIGINAL_SG_ID" || "$ORIGINAL_SG_ID" == "None" ]]; then
    echo -e "${RED}Error: could not resolve the original instance security group.${NC}"; exit 1
fi

echo -e "   Instance:        ${GREEN}${INSTANCE_ID}${NC}"
echo -e "   Original SG:     ${GREEN}${ORIGINAL_SG_ID}${NC}  (resting state target)"
echo -e "   Seeder role:     ${GREEN}${SEEDER_ROLE_NAME}${NC}"
echo

ISOLATION_SG_CANDIDATES=""   # collected across ENIs, de-duped later
CHANGES=0

# ---------------------------------------------------------------------------
# Step 1: Reset the Security Hub finding back to NEW (re-arms the beacon)
# ---------------------------------------------------------------------------
echo -e "${BLUE}[1/4] Security Hub finding...${NC}"

FINDINGS_JSON=$(aws_ securityhub get-findings \
    --filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],"ResourceId":[{"Value":"'"$INSTANCE_ARN"'","Comparison":"EQUALS"}]}' \
    --query 'Findings[].{Id:Id,ProductArn:ProductArn,Status:Workflow.Status}' \
    --output json 2>/dev/null || echo '[]')

FINDING_TOTAL=$(echo "$FINDINGS_JSON" | jq 'length')
if [[ "$FINDING_TOTAL" -eq 0 ]]; then
    echo -e "   ${YELLOW}No GuardDuty finding for this instance yet (nothing to reset).${NC}"
else
    # Reset any finding not already in NEW (NOTIFIED/RESOLVED/SUPPRESSED)
    RESET_COUNT=0
    while IFS=$'\t' read -r FID FARN FSTATUS; do
        [[ -z "$FID" ]] && continue
        if [[ "$FSTATUS" == "NEW" ]]; then
            echo -e "   ${GREEN}Finding already NEW${NC} (${FID##*/})"
            continue
        fi
        echo -e "   Finding status is ${YELLOW}${FSTATUS}${NC} -> resetting to ${GREEN}NEW${NC} (${FID##*/})"
        NOTE_ARG='Text=Demo reset: reverting workflow remediation,UpdatedBy=reset-script'
        run "set finding ${FID##*/} to NEW" \
            aws_ securityhub batch-update-findings \
                --finding-identifiers Id="$FID",ProductArn="$FARN" \
                --workflow Status=NEW \
                --note "$NOTE_ARG" \
                >/dev/null
        RESET_COUNT=$((RESET_COUNT+1)); CHANGES=$((CHANGES+1))
    done < <(echo "$FINDINGS_JSON" | jq -r '.[] | [.Id, .ProductArn, (.Status // "NEW")] | @tsv')
    [[ "$RESET_COUNT" -eq 0 ]] && echo -e "   ${GREEN}All findings already at resting state.${NC}"
fi
echo

# ---------------------------------------------------------------------------
# Step 2: Rebind every instance ENI back to the original instance SG
#         (discovers the isolation SG as "whatever SG is on an ENI that isn't
#          the original" and records it for cleanup)
# ---------------------------------------------------------------------------
echo -e "${BLUE}[2/4] Network isolation...${NC}"

# All ENIs attached to the instance (primary + any secondary), with their
# attachment ids and current group sets.
ENI_JSON=$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].NetworkInterfaces[].{Eni:NetworkInterfaceId,Attachment:Attachment.AttachmentId,Device:Attachment.DeviceIndex,Groups:Groups[].GroupId}' \
    --output json 2>/dev/null || echo '[]')

ENI_COUNT=$(echo "$ENI_JSON" | jq 'length')
if [[ "$ENI_COUNT" -eq 0 ]]; then
    echo -e "   ${YELLOW}Instance has no network interfaces (is it terminated?).${NC}"
else
    REBIND_COUNT=0
    while read -r ENI; do
        [[ -z "$ENI" || "$ENI" == "null" ]] && continue
        DEVICE=$(echo "$ENI_JSON" | jq -r --arg e "$ENI" '.[] | select(.Eni==$e) | .Device')
        CURRENT_GROUPS=$(echo "$ENI_JSON" | jq -r --arg e "$ENI" '.[] | select(.Eni==$e) | .Groups[]')

        # Is the original SG already (and only) attached?
        if [[ "$CURRENT_GROUPS" == "$ORIGINAL_SG_ID" ]]; then
            echo -e "   eth${DEVICE} (${ENI}): ${GREEN}already on original SG${NC}"
            continue
        fi

        # Any group that isn't the original SG is a candidate isolation SG.
        for G in $CURRENT_GROUPS; do
            if [[ "$G" != "$ORIGINAL_SG_ID" ]]; then
                ISOLATION_SG_CANDIDATES="$ISOLATION_SG_CANDIDATES $G"
            fi
        done

        echo -e "   eth${DEVICE} (${ENI}): on ${YELLOW}$(echo $CURRENT_GROUPS | tr '\n' ' ')${NC} -> rebinding to ${GREEN}${ORIGINAL_SG_ID}${NC}"
        run "rebind ${ENI} to ${ORIGINAL_SG_ID}" \
            aws_ ec2 modify-network-interface-attribute \
                --network-interface-id "$ENI" \
                --groups "$ORIGINAL_SG_ID" \
                >/dev/null
        REBIND_COUNT=$((REBIND_COUNT+1)); CHANGES=$((CHANGES+1))
    done < <(echo "$ENI_JSON" | jq -r '.[].Eni')
    [[ "$REBIND_COUNT" -eq 0 ]] && echo -e "   ${GREEN}All interfaces already at resting state.${NC}"
fi
echo

# ---------------------------------------------------------------------------
# Step 3: Strip the credential-neutralization from the seeder role.
#         Baseline (deployed state) = exactly one inline policy named
#         "CloudTrailSeeding" and zero attached managed policies. Anything
#         beyond that baseline is the workflow's neutralization, whatever form
#         it took (inline deny, managed-policy attach, session revocation).
# ---------------------------------------------------------------------------
echo -e "${BLUE}[3/4] Seeder-role credential neutralization...${NC}"

BASELINE_INLINE="CloudTrailSeeding"

if ! aws_ iam get-role --role-name "$SEEDER_ROLE_NAME" >/dev/null 2>&1; then
    echo -e "   ${YELLOW}Seeder role ${SEEDER_ROLE_NAME} not found (nothing to reset).${NC}"
else
    NEUTRALIZE_COUNT=0

    # 3a. Inline policies beyond the baseline -> delete them.
    INLINE_POLICIES=$(aws_ iam list-role-policies --role-name "$SEEDER_ROLE_NAME" \
        --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
    for P in $INLINE_POLICIES; do
        if [[ "$P" == "$BASELINE_INLINE" ]]; then
            continue
        fi
        echo -e "   Found extra inline policy ${YELLOW}${P}${NC} -> removing"
        run "delete inline policy ${P} from ${SEEDER_ROLE_NAME}" \
            aws_ iam delete-role-policy --role-name "$SEEDER_ROLE_NAME" --policy-name "$P" \
            >/dev/null
        NEUTRALIZE_COUNT=$((NEUTRALIZE_COUNT+1)); CHANGES=$((CHANGES+1))
    done

    # 3b. The baseline inline policy may have been OVERWRITTEN in place with a
    #     deny (same name). Detect an explicit Deny and restore the original.
    if echo "$INLINE_POLICIES" | tr '\t' '\n' | grep -qx "$BASELINE_INLINE"; then
        BASE_DOC=$(aws_ iam get-role-policy --role-name "$SEEDER_ROLE_NAME" \
            --policy-name "$BASELINE_INLINE" \
            --query 'PolicyDocument' --output json 2>/dev/null || echo '{}')
        if echo "$BASE_DOC" | jq -e '[.Statement[]? | select((.Effect=="Deny"))] | length > 0' >/dev/null 2>&1; then
            echo -e "   Baseline inline policy ${YELLOW}${BASELINE_INLINE}${NC} contains a Deny -> restoring original"
            RESTORE_DOC='{"Version":"2012-10-17","Statement":[{"Sid":"CloudTrailSeeding","Effect":"Allow","Action":["ec2:RunInstances","ec2:DescribeInstances","ec2:TerminateInstances","ec2:CreateTags"],"Resource":"*"},{"Sid":"PassRoleForInstanceProfile","Effect":"Allow","Action":"iam:PassRole","Resource":"*","Condition":{"StringEquals":{"iam:PassedToService":"ec2.amazonaws.com"}}}]}'
            run "restore original ${BASELINE_INLINE} policy document" \
                aws_ iam put-role-policy --role-name "$SEEDER_ROLE_NAME" \
                    --policy-name "$BASELINE_INLINE" \
                    --policy-document "$RESTORE_DOC" \
                >/dev/null
            NEUTRALIZE_COUNT=$((NEUTRALIZE_COUNT+1)); CHANGES=$((CHANGES+1))
        fi
    fi

    # 3c. Any attached managed policy -> baseline has none, so detach all.
    ATTACHED=$(aws_ iam list-attached-role-policies --role-name "$SEEDER_ROLE_NAME" \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    for ARN in $ATTACHED; do
        echo -e "   Found attached managed policy ${YELLOW}${ARN}${NC} -> detaching"
        run "detach managed policy ${ARN} from ${SEEDER_ROLE_NAME}" \
            aws_ iam detach-role-policy --role-name "$SEEDER_ROLE_NAME" --policy-arn "$ARN" \
            >/dev/null
        NEUTRALIZE_COUNT=$((NEUTRALIZE_COUNT+1)); CHANGES=$((CHANGES+1))
    done

    [[ "$NEUTRALIZE_COUNT" -eq 0 ]] && echo -e "   ${GREEN}Seeder role already at deployed baseline.${NC}"
fi
echo

# ---------------------------------------------------------------------------
# Step 4: Best-effort cleanup of orphaned isolation SGs the workflow created.
#         Only SGs discovered in step 2 (attached to the instance but not the
#         original) are candidates. We never touch the original SG or default.
# ---------------------------------------------------------------------------
echo -e "${BLUE}[4/4] Isolation security group cleanup...${NC}"

# De-dupe candidates
ISOLATION_SG_CANDIDATES=$(echo "$ISOLATION_SG_CANDIDATES" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

if [[ "$DELETE_ISOLATION_SG" != true ]]; then
    echo -e "   ${YELLOW}--keep-isolation-sg set; leaving isolation SGs in place.${NC}"
    [[ -n "$ISOLATION_SG_CANDIDATES" ]] && echo -e "   Discovered: $(echo $ISOLATION_SG_CANDIDATES | tr '\n' ' ')"
elif [[ -z "$ISOLATION_SG_CANDIDATES" ]]; then
    echo -e "   ${GREEN}No isolation security group found to clean up.${NC}"
else
    for SG in $ISOLATION_SG_CANDIDATES; do
        # Never delete the original or a default SG.
        if [[ "$SG" == "$ORIGINAL_SG_ID" ]]; then continue; fi
        SG_NAME=$(aws_ ec2 describe-security-groups --group-ids "$SG" \
            --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || echo "")
        if [[ "$SG_NAME" == "default" ]]; then
            echo -e "   ${YELLOW}Skipping default SG ${SG}.${NC}"; continue
        fi
        # Safe now that ENIs were rebound in step 2; delete may still fail if
        # the SG is referenced elsewhere, so this is best-effort.
        echo -e "   Deleting isolation SG ${YELLOW}${SG}${NC} (${SG_NAME})"
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "   ${YELLOW}[dry-run]${NC} would delete security group ${SG}"
        elif aws_ ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1; then
            echo -e "   ${GREEN}✓ Deleted ${SG}${NC}"; CHANGES=$((CHANGES+1))
        else
            echo -e "   ${YELLOW}⚠ Could not delete ${SG} (still referenced?). Leaving in place.${NC}"
        fi
    done
fi
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GREEN}  Dry run complete — no changes made.${NC}"
else
    echo -e "${GREEN}  Reset complete (${CHANGES} change(s) applied).${NC}"
fi
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo
echo -e "${BLUE}Resting state restored:${NC}"
echo -e "  • Finding workflow status: ${GREEN}NEW${NC} (beacon will resume on next tick)"
echo -e "  • Instance interfaces:     ${GREEN}original instance SG${NC}"
echo -e "  • Seeder role:             ${GREEN}deployed baseline${NC}"
echo
echo -e "${BLUE}Re-run the workflow:${NC} it will see a fresh NEW finding and remediate again."
if [[ "$DRY_RUN" != true ]]; then
    echo -e "${YELLOW}Tip:${NC} if the beacon was disabled, run 'make enable-beacon'."
fi

exit 0
