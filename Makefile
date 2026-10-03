.PHONY: help deploy verify enable-beacon disable-beacon logs outputs clean status

# Default values (can be overridden via environment variables)
AWS_REGION ?= us-west-1
AWS_PROFILE ?=
STACK_NAME ?= cryptomining-demo-$(shell whoami)

# Set up AWS CLI profile argument
PROFILE_ARG := $(if $(AWS_PROFILE),--profile $(AWS_PROFILE),)

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m # No Color

help: ## Show this help message
	@echo "$(BLUE)AWS Cryptomining Demo - Available Commands$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-18s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BLUE)Environment Variables:$(NC)"
	@echo "  AWS_REGION=$(AWS_REGION)"
	@echo "  AWS_PROFILE=$(AWS_PROFILE)"
	@echo "  STACK_NAME=$(STACK_NAME)"
	@echo ""
	@echo "$(BLUE)Examples:$(NC)"
	@echo "  make deploy                         # Deploy with defaults"
	@echo "  make deploy AWS_PROFILE=sandbox     # Deploy with specific profile"
	@echo "  make deploy AWS_REGION=us-east-1"
	@echo "  make enable-beacon"
	@echo "  make logs"
	@echo ""

deploy: ## Deploy the CloudFormation stack
	@./deploy.sh --region $(AWS_REGION) --stack-name $(STACK_NAME) $(if $(AWS_PROFILE),--profile $(AWS_PROFILE),)

deploy-with-beacon: ## Deploy with beacon enabled
	@./deploy.sh --region $(AWS_REGION) --stack-name $(STACK_NAME) --beacon-enabled

deploy-verify: ## Deploy and run verification checks
	@./deploy.sh --region $(AWS_REGION) --stack-name $(STACK_NAME) --verify

status: ## Show stack status
	@echo "$(BLUE)Stack Status:$(NC)"
	@aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].{Status:StackStatus,Created:CreationTime}' \
		--output table 2>/dev/null || echo "$(YELLOW)Stack not found$(NC)"

outputs: ## Show stack outputs
	@echo "$(BLUE)Stack Outputs:$(NC)"
	@aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
		--output table

enable-beacon: ## Enable the beacon schedule
	@echo "$(BLUE)Enabling beacon...$(NC)"
	@BEACON_RULE=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
		--output text); \
	aws $(PROFILE_ARG) events enable-rule --region $(AWS_REGION) --name $$BEACON_RULE && \
	echo "$(GREEN)✓ Beacon enabled (first invocation in 3 minutes)$(NC)"

disable-beacon: ## Disable the beacon schedule
	@echo "$(BLUE)Disabling beacon...$(NC)"
	@BEACON_RULE=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
		--output text); \
	aws $(PROFILE_ARG) events disable-rule --region $(AWS_REGION) --name $$BEACON_RULE && \
	echo "$(GREEN)✓ Beacon disabled$(NC)"

logs: ## Tail beacon Lambda logs
	@echo "$(BLUE)Tailing beacon logs (Ctrl+C to exit)...$(NC)"
	@USER_ID=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`UserIdentifier`].OutputValue' \
		--output text); \
	aws $(PROFILE_ARG) logs tail /aws/lambda/cryptomining-demo-$$USER_ID-beacon \
		--region $(AWS_REGION) \
		--follow \
		--since 5m

verify: ## Run verification checks
	@echo "$(BLUE)Running verification checks...$(NC)"
	@echo ""
	@USER_ID=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`UserIdentifier`].OutputValue' \
		--output text); \
	echo "$(BLUE)1. Checking SSM manifest parameter...$(NC)"; \
	if aws $(PROFILE_ARG) ssm get-parameter \
		--region $(AWS_REGION) \
		--name "/cryptomining-demo/$$USER_ID/manifest" \
		--query 'Parameter.Value' \
		--output text | jq -e '.version == 1' > /dev/null 2>&1; then \
		echo "$(GREEN)✓ SSM manifest parameter exists$(NC)"; \
	else \
		echo "$(YELLOW)✗ SSM manifest parameter not found or invalid$(NC)"; \
	fi; \
	echo ""; \
	echo "$(BLUE)2. Checking CloudTrail seeding...$(NC)"; \
	if aws $(PROFILE_ARG) cloudtrail lookup-events \
		--region $(AWS_REGION) \
		--lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
		--max-results 10 \
		--query 'Events[].[EventTime,Username]' \
		--output text | grep -q 'ASIA'; then \
		echo "$(GREEN)✓ CloudTrail seeding successful (ASIA* credentials found)$(NC)"; \
	else \
		echo "$(YELLOW)⚠ CloudTrail seeding may not have completed yet$(NC)"; \
	fi; \
	echo ""; \
	echo "$(BLUE)3. Checking EC2 instance...$(NC)"; \
	INSTANCE_ID=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceId`].OutputValue' \
		--output text); \
	INSTANCE_STATE=$$(aws $(PROFILE_ARG) ec2 describe-instances \
		--region $(AWS_REGION) \
		--instance-ids $$INSTANCE_ID \
		--query 'Reservations[0].Instances[0].State.Name' \
		--output text); \
	if [ "$$INSTANCE_STATE" = "running" ]; then \
		echo "$(GREEN)✓ EC2 instance is running$(NC)"; \
	else \
		echo "$(YELLOW)⚠ EC2 instance state: $$INSTANCE_STATE$(NC)"; \
	fi; \
	echo ""; \
	echo "$(BLUE)4. Checking Security Hub finding...$(NC)"; \
	INSTANCE_ARN=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceArn`].OutputValue' \
		--output text); \
	FINDING_COUNT=$$(aws $(PROFILE_ARG) securityhub get-findings \
		--region $(AWS_REGION) \
		--filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],"ResourceId":[{"Value":"'$$INSTANCE_ARN'","Comparison":"EQUALS"}]}' \
		--query 'length(Findings)' \
		--output text 2>/dev/null || echo "0"); \
	if [ "$$FINDING_COUNT" -gt 0 ]; then \
		echo "$(GREEN)✓ Security Hub finding exists ($$FINDING_COUNT found)$(NC)"; \
	else \
		echo "$(YELLOW)⚠ No Security Hub findings yet (beacon may need to run first)$(NC)"; \
	fi

finding: ## Show the Security Hub finding
	@INSTANCE_ARN=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs[?OutputKey==`SimulatedInstanceArn`].OutputValue' \
		--output text); \
	aws $(PROFILE_ARG) securityhub get-findings \
		--region $(AWS_REGION) \
		--filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}],"ResourceId":[{"Value":"'$$INSTANCE_ARN'","Comparison":"EQUALS"}]}' \
		--query 'Findings[0].{Id:Id,Status:Workflow.Status,Severity:Severity.Label,Title:Title,UpdatedAt:UpdatedAt}' \
		--output table

events: ## Show recent CloudFormation stack events
	@aws $(PROFILE_ARG) cloudformation describe-stack-events \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--query 'StackEvents[0:20].[Timestamp,ResourceStatus,ResourceType,ResourceStatusReason]' \
		--output table

clean: ## Delete the CloudFormation stack
	@echo "$(YELLOW)Warning: This will delete the entire stack.$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [ "$$REPLY" = "y" ] || [ "$$REPLY" = "Y" ]; then \
		echo "$(BLUE)Disabling beacon...$(NC)"; \
		BEACON_RULE=$$(aws $(PROFILE_ARG) cloudformation describe-stacks \
			--region $(AWS_REGION) \
			--stack-name $(STACK_NAME) \
			--query 'Stacks[0].Outputs[?OutputKey==`BeaconScheduleRuleName`].OutputValue' \
			--output text 2>/dev/null); \
		if [ -n "$$BEACON_RULE" ]; then \
			aws $(PROFILE_ARG) events disable-rule --region $(AWS_REGION) --name $$BEACON_RULE 2>/dev/null || true; \
		fi; \
		echo "$(BLUE)Deleting stack...$(NC)"; \
		aws $(PROFILE_ARG) cloudformation delete-stack \
			--region $(AWS_REGION) \
			--stack-name $(STACK_NAME); \
		echo "$(BLUE)Waiting for deletion to complete...$(NC)"; \
		aws $(PROFILE_ARG) cloudformation wait stack-delete-complete \
			--region $(AWS_REGION) \
			--stack-name $(STACK_NAME) 2>/dev/null && \
		echo "$(GREEN)✓ Stack deleted successfully$(NC)" || \
		echo "$(YELLOW)Stack deletion in progress (check status with: make status)$(NC)"; \
	else \
		echo "$(YELLOW)Cancelled$(NC)"; \
	fi
