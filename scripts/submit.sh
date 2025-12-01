#!/usr/bin/env bash
# Submits an application declaration to the ZLAF registry event bus.
# Run from the application account using its own AWS credentials — the app
# account may only PutEvents; it has no access to registry infrastructure.
#
# Usage:
#   APP_PROFILE=app-c REGISTRY_BUS_ARN=<arn> scripts/submit.sh app-c 1 true
#   APP_PROFILE=app-d REGISTRY_BUS_ARN=<arn> scripts/submit.sh app-d 2 false
#
# Args:
#   $1  app_id     (app-c | app-d)
#   $2  revision   integer; must be greater than any previous accepted revision
#   $3  enabled    true | false  (default: true)
#
# Required env:
#   APP_PROFILE        AWS profile for the application account
#   REGISTRY_BUS_ARN   EventBridge bus ARN in the registry account
set -euo pipefail

APP_ID="${1:?app_id required}"
REVISION="${2:?revision required}"
ENABLED="${3:-true}"

PROFILE="${APP_PROFILE:-$APP_ID}"
[ -n "${REGISTRY_BUS_ARN:-}" ] || { echo "FAIL: REGISTRY_BUS_ARN is not set" >&2; exit 1; }

LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"

FQDN=""
ACCOUNT_ID=""
for i in 0 1; do
    id=$(jq -r ".applications[$i].id" "$LAB")
    if [ "$id" = "$APP_ID" ]; then
        FQDN=$(jq -r ".applications[$i].fqdn"    "$LAB")
        ACCOUNT_ID=$(jq -r ".applications[$i].account" "$LAB")
        break
    fi
done
[ -z "$FQDN" ] && { echo "FAIL: unknown app_id $APP_ID" >&2; exit 1; }

REGION=$(jq -r .region "$LAB")

# Build the detail JSON, then the full event entry with Detail as a string
DETAIL=$(jq -n \
    --arg    app_id      "$APP_ID" \
    --arg    fqdn        "$FQDN" \
    --arg    account_id  "$ACCOUNT_ID" \
    --arg    region      "$REGION" \
    --argjson port       443 \
    --arg    environment "prod" \
    --argjson enabled    "$ENABLED" \
    --argjson revision   "$REVISION" \
    '{app_id:$app_id, fqdn:$fqdn, account_id:$account_id, region:$region,
      port:$port, protocol:"tcp", environment:$environment,
      enabled:$enabled, revision:$revision}')

ENTRY=$(jq -n \
    --arg source       "enterprise.application-access" \
    --arg detail_type  "PrivateApplicationRegistrationRequested" \
    --arg detail       "$DETAIL" \
    --arg bus          "$REGISTRY_BUS_ARN" \
    '{Source:$source, DetailType:$detail_type, Detail:$detail, EventBusName:$bus}')

echo "Submitting: $APP_ID revision=$REVISION enabled=$ENABLED"
echo "  fqdn=$FQDN  account=$ACCOUNT_ID"

aws --profile "$PROFILE" --region "$REGION" events put-events \
    --entries "[$ENTRY]"

echo "Submitted."
