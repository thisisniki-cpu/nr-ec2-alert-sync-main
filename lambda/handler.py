"""Lambda handler: syncs EC2 'application' tags to New Relic Alert Policies.

Trigger sources
---------------
1. EC2 Instance State-change Notification (EventBridge) — instance enters 'running'
2. Tag Change on Resource (EventBridge) — 'application' tag added/changed on an instance
3. Scheduled Event (EventBridge) — hourly full-sync as a safety net
4. Direct invocation — pass {"instance_ids": ["i-xxx"]} for ad-hoc testing
"""

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Optional

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger(__name__)
logger.setLevel(getattr(logging, log_level, logging.INFO))

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
NR_GRAPHQL_URL = "https://api.newrelic.com/graphql"
NR_SECRET_NAME = os.environ["NR_SECRET_NAME"]


# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------
def get_nr_credentials() -> dict:
    """Retrieve New Relic credentials from AWS Secrets Manager."""
    client = boto3.client("secretsmanager")
    try:
        response = client.get_secret_value(SecretId=NR_SECRET_NAME)
        return json.loads(response["SecretString"])
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        logger.error("Failed to retrieve secret '%s': %s", NR_SECRET_NAME, code)
        raise


# ---------------------------------------------------------------------------
# New Relic NerdGraph helpers
# ---------------------------------------------------------------------------
def _graphql_request(api_key: str, query: str, variables: Optional[dict] = None) -> dict:
    """Execute a NerdGraph GraphQL request and return the parsed response."""
    payload: dict = {"query": query}
    if variables:
        payload["variables"] = variables

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        NR_GRAPHQL_URL,
        data=data,
        headers={"Content-Type": "application/json", "API-Key": api_key},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        logger.error("NerdGraph HTTP %s: %s", exc.code, body)
        raise
    except urllib.error.URLError as exc:
        logger.error("NerdGraph connection error: %s", exc.reason)
        raise

    if "errors" in result:
        logger.error("NerdGraph errors: %s", result["errors"])
        raise RuntimeError(f"NerdGraph returned errors: {result['errors']}")

    return result


def list_existing_policies(api_key: str, account_id: int) -> set:
    """Return the set of existing Alert Policy names for the given NR account.

    Handles pagination automatically via nextCursor.
    """
    query = """
    query ListAlertPolicies($accountId: Int!, $cursor: String) {
      actor {
        account(id: $accountId) {
          alerts {
            policiesSearch(cursor: $cursor) {
              policies { id name }
              nextCursor
            }
          }
        }
      }
    }
    """
    policy_names: set = set()
    cursor: Optional[str] = None

    while True:
        variables: dict = {"accountId": account_id}
        if cursor:
            variables["cursor"] = cursor

        result = _graphql_request(api_key, query, variables)
        search = result["data"]["actor"]["account"]["alerts"]["policiesSearch"]

        for policy in search.get("policies", []):
            policy_names.add(policy["name"])

        cursor = search.get("nextCursor")
        if not cursor:
            break

    logger.info("Found %d existing New Relic alert policies", len(policy_names))
    return policy_names


def create_alert_policy(api_key: str, account_id: int, policy_name: str) -> dict:
    """Create a New Relic Alert Policy and return the created policy object."""
    mutation = """
    mutation CreateAlertPolicy($accountId: Int!, $name: String!) {
      alertsPolicyCreate(accountId: $accountId, policy: {
        incidentPreference: PER_POLICY
        name: $name
      }) {
        policy { id name incidentPreference }
      }
    }
    """
    result = _graphql_request(
        api_key, mutation, {"accountId": account_id, "name": policy_name}
    )
    policy = result["data"]["alertsPolicyCreate"]["policy"]
    logger.info(
        "Created New Relic alert policy: name='%s' id=%s", policy["name"], policy["id"]
    )
    return policy


# ---------------------------------------------------------------------------
# EC2 tag helpers
# ---------------------------------------------------------------------------
def get_application_tags_for_instances(instance_ids: list) -> set:
    """Return the set of 'application' tag values for the given instance IDs."""
    ec2 = boto3.client("ec2")
    app_names: set = set()

    try:
        response = ec2.describe_instances(InstanceIds=instance_ids)
    except ClientError as exc:
        logger.error("Failed to describe instances %s: %s", instance_ids, exc)
        raise

    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            instance_id = instance["InstanceId"]
            app_tag = next(
                (t["Value"] for t in instance.get("Tags", []) if t["Key"] == "application"),
                None,
            )
            if app_tag:
                logger.info("Instance %s → application=%s", instance_id, app_tag)
                app_names.add(app_tag)
            else:
                logger.warning("Instance %s has no 'application' tag — skipping", instance_id)

    return app_names


def get_all_ec2_application_tags() -> set:
    """Full scan: return all unique 'application' tag values across running instances."""
    ec2 = boto3.client("ec2")
    app_names: set = set()
    paginator = ec2.get_paginator("describe_instances")

    pages = paginator.paginate(
        Filters=[
            {"Name": "tag-key", "Values": ["application"]},
            {"Name": "instance-state-name", "Values": ["running", "pending"]},
        ]
    )

    for page in pages:
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                app_tag = next(
                    (t["Value"] for t in instance.get("Tags", []) if t["Key"] == "application"),
                    None,
                )
                if app_tag:
                    logger.info("Instance %s → application=%s", instance["InstanceId"], app_tag)
                    app_names.add(app_tag)

    logger.info("Full scan found %d unique application tag values", len(app_names))
    return app_names


# ---------------------------------------------------------------------------
# Core sync logic
# ---------------------------------------------------------------------------
def sync_policies(app_names: set, api_key: str, account_id: int) -> dict:
    """Ensure a New Relic Alert Policy exists for each application name.

    Returns a summary dict with 'created', 'skipped', and optionally 'failed' lists.
    """
    if not app_names:
        logger.info("No application names to sync")
        return {"created": [], "skipped": []}

    existing = list_existing_policies(api_key, account_id)
    created, skipped, failed = [], [], []

    for app_name in sorted(app_names):
        if app_name in existing:
            logger.info("Policy '%s' already exists — skipping", app_name)
            skipped.append(app_name)
        else:
            try:
                create_alert_policy(api_key, account_id, app_name)
                created.append(app_name)
            except Exception as exc:  # pylint: disable=broad-except
                logger.error("Failed to create policy for '%s': %s", app_name, exc)
                failed.append(app_name)

    logger.info(
        "Sync complete — created=%d, skipped=%d, failed=%d",
        len(created),
        len(skipped),
        len(failed),
    )
    result = {"created": created, "skipped": skipped}
    if failed:
        result["failed"] = failed
    return result


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------
def lambda_handler(event: dict, context) -> dict:  # noqa: ANN001
    """Route the incoming EventBridge / direct-invocation event to the right handler."""
    logger.info("Event: %s", json.dumps(event))

    creds = get_nr_credentials()
    nr_api_key: str = creds["nr_api_key"]
    nr_account_id: int = int(creds["nr_account_id"])

    source = event.get("source", "")
    detail_type = event.get("detail-type", "")

    # ------------------------------------------------------------------
    # Trigger 1: EC2 instance entered 'running' state
    # ------------------------------------------------------------------
    if source == "aws.ec2" and detail_type == "EC2 Instance State-change Notification":
        instance_id: str = event["detail"]["instance-id"]
        logger.info("EC2 state-change trigger: instance=%s", instance_id)
        app_names = get_application_tags_for_instances([instance_id])

    # ------------------------------------------------------------------
    # Trigger 2: 'application' tag was added / changed on an EC2 instance
    # ------------------------------------------------------------------
    elif source == "aws.ec2" and detail_type == "Tag Change on Resource":
        changed = event["detail"].get("changed-tag-keys", [])
        if "application" not in changed:
            logger.info("Tag change did not affect 'application' tag — skipping")
            return {"statusCode": 200, "body": "no-op: irrelevant tag change"}

        resource_id: str = event["detail"]["resource-id"]
        # The 'tags' map in the event contains the full current tag set
        app_tag = event["detail"].get("tags", {}).get("application")
        if app_tag:
            logger.info("Tag-change trigger: resource=%s application=%s", resource_id, app_tag)
            app_names = {app_tag}
        else:
            # Tag was removed — nothing to create
            logger.info("'application' tag removed from %s — nothing to create", resource_id)
            return {"statusCode": 200, "body": "no-op: application tag removed"}

    # ------------------------------------------------------------------
    # Trigger 3: Scheduled full-sync
    # ------------------------------------------------------------------
    elif detail_type == "Scheduled Event":
        logger.info("Scheduled trigger: performing full EC2 scan")
        app_names = get_all_ec2_application_tags()

    # ------------------------------------------------------------------
    # Trigger 4: Direct / manual invocation
    # ------------------------------------------------------------------
    elif "instance_ids" in event:
        ids = event["instance_ids"]
        logger.info("Direct invocation with instance_ids=%s", ids)
        app_names = get_application_tags_for_instances(ids) if ids else get_all_ec2_application_tags()

    # ------------------------------------------------------------------
    # Fallback: unknown source — do a full scan so nothing is missed
    # ------------------------------------------------------------------
    else:
        logger.warning(
            "Unknown trigger (source='%s', detail-type='%s') — falling back to full scan",
            source,
            detail_type,
        )
        app_names = get_all_ec2_application_tags()

    result = sync_policies(app_names, nr_api_key, nr_account_id)
    return {"statusCode": 200, "body": json.dumps(result)}
