.PHONY: init plan apply destroy test-invoke logs dlq-check

TF_DIR  := terraform
FUNC    := $(shell terraform -chdir=$(TF_DIR) output -raw lambda_function_name 2>/dev/null)
REGION  := $(shell terraform -chdir=$(TF_DIR) output -json 2>/dev/null | jq -r '.aws_region.value // "us-east-1"')

# ── Terraform lifecycle ──────────────────────────────────────────────────────

init:
	terraform -chdir=$(TF_DIR) init

plan:
	terraform -chdir=$(TF_DIR) plan

apply:
	terraform -chdir=$(TF_DIR) apply

destroy:
	terraform -chdir=$(TF_DIR) destroy

# ── Testing & verification ───────────────────────────────────────────────────

## Full-sync invocation (equivalent to the hourly schedule trigger)
test-invoke:
	@echo "Invoking Lambda for full EC2 sync..."
	aws lambda invoke \
		--function-name $(FUNC) \
		--region $(REGION) \
		--payload '{"detail-type":"Scheduled Event","source":"aws.events"}' \
		--log-type Tail \
		--cli-binary-format raw-in-base64-out \
		/tmp/lambda-response.json \
	| jq -r '.LogResult' | base64 -d
	@echo "\n--- Response ---"
	@cat /tmp/lambda-response.json | jq .

## Tail live CloudWatch logs
logs:
	aws logs tail /aws/lambda/$(FUNC) --follow --region $(REGION)

## Check DLQ message count
dlq-check:
	@DLQ_URL=$$(terraform -chdir=$(TF_DIR) output -raw dlq_url); \
	aws sqs get-queue-attributes \
		--queue-url $$DLQ_URL \
		--attribute-names ApproximateNumberOfMessages \
		--region $(REGION) \
	| jq '.Attributes'
