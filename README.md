# nr-ec2-alert-sync

Serverless solution that keeps New Relic Alert Policies in sync with the
`application` tag on AWS EC2 instances.  When an instance enters the `running`
state — or its `application` tag changes — a Lambda function is invoked to
create the corresponding New Relic Alert Policy (if it does not already exist).
An hourly scheduled run catches anything the event-driven path may have missed.

---

## Architecture

```
                  ┌────────────────────────────────────────────────────────────┐
                  │                        AWS Account                         │
                  │                                                             │
  EC2 → running ──┼──┐                                                         │
                  │  │  ┌──────────────────────────────────────────────────┐   │
  app tag change ─┼──┼─▶│              Amazon EventBridge                  │   │
                  │  │  │                                                   │   │
  hourly schedule ┼──┘  │  Rule 1: EC2 State-change (state=running)        │   │
                  │     │  Rule 2: Tag Change on Resource (key=application) │   │
                  │     │  Rule 3: rate(1 hour) — scheduled full-sync       │   │
                  │     └───────────────────┬──────────────────────────────┘   │
                  │                         │ async invoke (retry x3 + DLQ)    │
                  │                         ▼                                   │
                  │     ┌──────────────────────────────────────────────────┐   │
                  │     │                 AWS Lambda                        │   │
                  │     │           nr-ec2-alert-sync-prod                  │   │
                  │     │                                                   │   │
                  │     │  1. Identify trigger & collect instance IDs       │   │
                  │     │  2. Read 'application' tag via DescribeInstances  │   │
                  │     │  3. List existing NR Alert Policies (NerdGraph)   │   │
                  │     │  4. Create any missing policies                   │   │
                  │     └───┬─────────────────────┬──────────────────────┬─┘   │
                  │         │                     │                      │      │
                  │         ▼                     ▼                      ▼      │
                  │  ┌─────────────┐  ┌──────────────────┐  ┌────────────────┐│
                  │  │  Secrets    │  │  CloudWatch Logs  │  │  SQS Dead-    ││
                  │  │  Manager    │  │  (30-day retain)  │  │  Letter Queue ││
                  │  │  (NR creds) │  └──────────────────┘  │  (14-day DLQ) ││
                  │  └──────┬──────┘                         └────────────────┘│
                  │         │                                                   │
                  │  ┌──────▼────────────────────────────────────────────────┐ │
                  │  │                    Amazon EC2                          │ │
                  │  │   i-aaaa  tag: application=app-api                    │ │
                  │  │   i-bbbb  tag: application=app-web                    │ │
                  │  └───────────────────────────────────────────────────────┘ │
                  └────────────────────────────────────────────────────────────┘
                                            │
                              HTTPS  ──────▶│ NerdGraph (GraphQL) API
                                            ▼
                  ┌────────────────────────────────────────────────────────────┐
                  │                       New Relic                            │
                  │                                                             │
                  │   Alert Policy: app-api  (incidentPreference: PER_POLICY)  │
                  │   Alert Policy: app-web  (incidentPreference: PER_POLICY)  │
                  └────────────────────────────────────────────────────────────┘
```

---

## Design Choices

### Trigger strategy — three complementary rules

| Rule | Event | Why |
|------|-------|-----|
| EC2 State-change | `state=running` | Near-real-time: fires as soon as the instance is reachable. Tags set at launch are present. |
| Tag Change on Resource | `changed-tag-keys=[application]` | Catches instances launched without tags, then tagged later by automation. |
| Scheduled (hourly) | `rate(1 hour)` | Safety net for pre-existing instances, eventual-consistency gaps, and cold starts after deployments. |

### Idempotency

Before creating a policy the Lambda lists all existing policies via NerdGraph's
`policiesSearch` (with cursor-based pagination) and skips any name that already
exists.  Multiple Lambda invocations for the same application are therefore safe.

### Resilience

- **EventBridge retry**: each target is configured with `maximum_retry_attempts=3`
  and a 1-hour event age window before the event is dropped.
- **Lambda async retry**: `maximum_retry_attempts=2` on the Lambda async
  invocation config.
- **Dead-Letter Queue**: failed events are sent to an SQS DLQ (14-day retention)
  for inspection and manual replay.
- **Structured logging**: every invocation logs the trigger source, discovered
  application names, and the create/skip/fail outcome at INFO level.  Set
  `LOG_LEVEL=DEBUG` for full request/response traces.

### Secrets management

New Relic credentials (API key + account ID) are stored as a JSON object in
AWS Secrets Manager.  The secret ARN is injected into the Lambda as an
environment variable; the actual value is fetched at runtime.  Terraform
bootstraps the initial value but uses `ignore_changes` so subsequent rotations
via the Secrets Manager console or CLI do not cause plan diffs.

### Infrastructure as Code

All AWS resources are defined in Terraform (`~>5.0`).  The Lambda deployment
package is produced by Terraform's built-in `archive_file` data source — no
separate build step is needed because the handler uses only Python's standard
library and the `boto3` SDK pre-installed in the Lambda runtime.

### No CloudTrail dependency

The two event-driven rules use native EventBridge source events
(`aws.ec2` state-change and tag-change), **not** CloudTrail API-call events.
This avoids the CloudTrail propagation delay (up to 15 min) and the requirement
that CloudTrail be enabled in the account.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.5+ |
| AWS CLI | 2.x |
| Python | 3.12 (Lambda runtime — local runs only) |
| jq | any (used in Makefile helpers) |

AWS credentials must have permissions to create Lambda, IAM, EventBridge,
CloudWatch, Secrets Manager, and SQS resources.

A **New Relic User API key** (`NRAK-...`) with the *NerdGraph* permission is
required.  Create one at: **one.newrelic.com → (user menu) → API keys → Create key → User**.

---

## Setup & Deployment

### 1. Clone / copy this repository

```bash
git clone <repo-url>
cd nr-ec2-alert-sync
```

### 2. Create your Terraform variables file

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
aws_region    = "us-east-1"          # your target region
nr_api_key    = "NRAK-..."           # New Relic User API key
nr_account_id = "1234567"            # New Relic account ID
```

> `terraform.tfvars` is git-ignored — do **not** commit it.

### 3. Deploy

```bash
make init
make plan    # review the plan
make apply
```

Terraform will:
- Package `lambda/handler.py` into a zip
- Create all AWS resources
- Bootstrap the Secrets Manager secret with your NR credentials

### 4. Verify the deployment

```bash
# Tail live Lambda logs
make logs

# Trigger a full sync manually and view the result
make test-invoke

# Check for any failures in the DLQ
make dlq-check
```

Expected `test-invoke` output for a clean environment:
```json
{"statusCode": 200, "body": "{\"created\": [\"app-api\", \"app-web\"], \"skipped\": []}"}
```

On subsequent runs the same applications appear in `skipped` (idempotent).

---

## Rotating the New Relic API key

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform -chdir=terraform output -raw secrets_manager_secret_name)" \
  --secret-string '{"nr_api_key":"NRAK-NEW...","nr_account_id":"1234567"}'
```

Terraform will not overwrite this change on the next `apply` (protected by
`ignore_changes`).

---

## Verifying New Relic Alert Policies

After the Lambda runs, confirm the policies exist via the NerdGraph Explorer or:

```bash
curl -s -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: $NR_API_KEY" \
  -d '{
    "query": "{ actor { account(id: YOUR_ACCOUNT_ID) { alerts { policiesSearch { policies { id name } } } } } }"
  }' | jq '.data.actor.account.alerts.policiesSearch.policies[]'
```

---

## Project Layout

```
nr-ec2-alert-sync/
├── lambda/
│   └── handler.py          # Lambda function (stdlib + boto3 only)
├── terraform/
│   ├── providers.tf        # AWS + archive provider versions
│   ├── variables.tf        # All input variables with descriptions
│   ├── main.tf             # Lambda, Secrets Manager, CloudWatch, SQS DLQ
│   ├── eventbridge.tf      # Three EventBridge rules + targets + permissions
│   ├── iam.tf              # Least-privilege IAM role and policy
│   ├── outputs.tf          # Useful resource identifiers
│   └── terraform.tfvars.example
├── Makefile                # Convenience targets (init/plan/apply/test)
└── README.md
```

---

## Teardown

```bash
make destroy
```

> The Secrets Manager secret has a 7-day recovery window; it will not be
> deleted immediately.
