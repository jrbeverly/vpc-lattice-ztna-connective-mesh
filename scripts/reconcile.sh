#!/usr/bin/env bash
# Reconcile validation for app-c.
#
# Deliberately deletes app-c's service-network association while desired state
# remains enabled and ACTIVE, then invokes reconcile explicitly and observes:
#   1. reconcile detects the missing association and starts a repair execution
#   2. the repair execution restores only the association (no duplicate resources)
#   3. app-c returns to VERIFYING; verify.sh can advance it to ACTIVE
#
# Run after Phase 3 is active and app-c is ACTIVE.
#
# Required env:
#   APP_C_PROFILE    AWS profile for the app-c account
#   REGISTRY_PROFILE AWS profile for the registry account
#   LAMBDA_ARN       ARN of zlaf-registry-controller Lambda function
#   REGISTRY_TABLE   DynamoDB table name (zlaf-registry)
#
# Optional:
#   REGISTRY_REGION  (default: ca-central-1)
set -euo pipefail

REGION="${REGISTRY_REGION:-ca-central-1}"
REGISTRY_TABLE="${REGISTRY_TABLE:-zlaf-registry}"
LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"
EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

[ -n "${LAMBDA_ARN:-}" ] || { echo "FAIL: LAMBDA_ARN not set" >&2; exit 1; }

get_state() {
    aws --profile "$REGISTRY_PROFILE" --region "$REGION" dynamodb get-item \
        --table-name "$REGISTRY_TABLE" \
        --key '{"app_id":{"S":"app-c"}}' \
        --output json
}

# ── 1. Confirm app-c is ACTIVE before inducing drift ─────────────────────────
echo "=== reconcile: confirm app-c is ACTIVE ==="
BEFORE=$(get_state)
STATE=$(echo "$BEFORE" | jq -r '.Item.lifecycle_state.S // "UNKNOWN"')
echo "  state=$STATE"
[ "$STATE" = "ACTIVE" ] || { echo "FAIL: app-c must be ACTIVE before reconcile test (got $STATE)" >&2; exit 1; }

ASSOC_ID=$(echo "$BEFORE" | jq -r '.Item.observed_assoc_id.S // ""')
SVC_ID=$(echo "$BEFORE" | jq -r '.Item.observed_svc_id.S // ""')
TG_ID=$(echo "$BEFORE" | jq -r '.Item.observed_tg_id.S // ""')
LST_ID=$(echo "$BEFORE" | jq -r '.Item.observed_lst_id.S // ""')
echo "  assoc_id=$ASSOC_ID  svc_id=$SVC_ID  tg_id=$TG_ID"

[ -n "$ASSOC_ID" ] || { echo "FAIL: no observed_assoc_id in registry" >&2; exit 1; }

echo "$BEFORE" > "$EVIDENCE/reconcile-before-app-c.json"
echo "  saved evidence/reconcile-before-app-c.json"

# Snapshot current Lattice inventory (resource counts before repair)
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-services \
    --output json > "$EVIDENCE/reconcile-before-lattice.json" 2>/dev/null || true
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-target-groups \
    --output json >> "$EVIDENCE/reconcile-before-lattice.json" 2>/dev/null || true

# ── 2. Delete the association to induce drift ─────────────────────────────────
echo "=== reconcile: deleting association $ASSOC_ID (induced drift) ==="
aws --profile "$APP_C_PROFILE" --region "$REGION" \
    vpc-lattice delete-service-network-service-association \
    --service-network-service-association-identifier "$ASSOC_ID"
echo "  association deletion requested"

# Wait for deletion to complete
for i in $(seq 1 20); do
    STATUS=$(aws --profile "$APP_C_PROFILE" --region "$REGION" \
        vpc-lattice get-service-network-service-association \
        --service-network-service-association-identifier "$ASSOC_ID" \
        --query 'status' --output text 2>/dev/null || echo "DELETED")
    echo "  try $i: association status=$STATUS"
    [ "$STATUS" = "DELETED" ] || [ "$STATUS" = "DELETED" ] && break
    [[ "$STATUS" == *"NOT_FOUND"* ]] && break
    sleep 5
done
echo "  association deleted"

# ── 3. Invoke reconcile explicitly ───────────────────────────────────────────
echo "=== reconcile: invoking Lambda reconcile task ==="
INVOKE_RESULT=$(aws --profile "$REGISTRY_PROFILE" --region "$REGION" \
    lambda invoke \
    --function-name "$LAMBDA_ARN" \
    --payload '{"task":"reconcile"}' \
    --cli-binary-format raw-in-base64-out \
    /dev/stdout 2>/dev/null)
echo "  result: $INVOKE_RESULT"
REPAIRED=$(echo "$INVOKE_RESULT" | jq -r '.repaired // 0' 2>/dev/null || echo "unknown")
echo "  repaired count: $REPAIRED"

# ── 4. Wait for repair execution to complete (VERIFYING) ─────────────────────
echo "=== reconcile: waiting for app-c to reach VERIFYING ==="
for i in $(seq 1 40); do
    STATE=$(aws --profile "$REGISTRY_PROFILE" --region "$REGION" dynamodb get-item \
        --table-name "$REGISTRY_TABLE" \
        --key '{"app_id":{"S":"app-c"}}' \
        --query 'Item.lifecycle_state.S' --output text 2>/dev/null || echo "UNKNOWN")
    echo "  try $i: state=$STATE"
    [ "$STATE" = "VERIFYING" ] && break
    sleep 15
done
[ "$STATE" = "VERIFYING" ] || { echo "FAIL: app-c did not reach VERIFYING after repair (last=$STATE)" >&2; exit 1; }

# ── 5. After-repair snapshot ──────────────────────────────────────────────────
AFTER=$(get_state)
echo "$AFTER" > "$EVIDENCE/reconcile-after-app-c.json"
echo "  saved evidence/reconcile-after-app-c.json"

NEW_ASSOC_ID=$(echo "$AFTER" | jq -r '.Item.observed_assoc_id.S // ""')
NEW_SVC_ID=$(echo "$AFTER" | jq -r '.Item.observed_svc_id.S // ""')
NEW_TG_ID=$(echo "$AFTER" | jq -r '.Item.observed_tg_id.S // ""')
NEW_LST_ID=$(echo "$AFTER" | jq -r '.Item.observed_lst_id.S // ""')
echo "  new assoc_id=$NEW_ASSOC_ID"
echo "  svc_id=$NEW_SVC_ID (was: $SVC_ID)"
echo "  tg_id=$NEW_TG_ID (was: $TG_ID)"

# Snapshot Lattice inventory after repair (should show same resource counts)
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-services \
    --output json > "$EVIDENCE/reconcile-after-lattice.json" 2>/dev/null || true
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-target-groups \
    --output json >> "$EVIDENCE/reconcile-after-lattice.json" 2>/dev/null || true
echo "  saved evidence/reconcile-after-lattice.json"

# ── 6. Assertion checks ───────────────────────────────────────────────────────
FAIL=0

[ "$REPAIRED" = "1" ] || {
    echo "FAIL: reconcile reported repaired=$REPAIRED, expected 1" >&2; FAIL=1
}

# Service, TG, and listener IDs must be unchanged (no duplicates created)
[ "$NEW_SVC_ID" = "$SVC_ID" ] || {
    echo "FAIL: service ID changed ($SVC_ID → $NEW_SVC_ID) — duplicate service created" >&2; FAIL=1
}
[ "$NEW_TG_ID" = "$TG_ID" ] || {
    echo "FAIL: target group ID changed ($TG_ID → $NEW_TG_ID) — duplicate TG created" >&2; FAIL=1
}
[ "$NEW_LST_ID" = "$LST_ID" ] || {
    echo "FAIL: listener ID changed ($LST_ID → $NEW_LST_ID) — duplicate listener created" >&2; FAIL=1
}

# New association must exist and be different from the deleted one
[ -n "$NEW_ASSOC_ID" ] || {
    echo "FAIL: no new observed_assoc_id after repair" >&2; FAIL=1
}
[ "$NEW_ASSOC_ID" != "$ASSOC_ID" ] || {
    echo "FAIL: association ID unchanged — deletion was not detected" >&2; FAIL=1
}

# New association must be ACTIVE in Lattice
if [ -n "$NEW_ASSOC_ID" ]; then
    ASSOC_STATUS=$(aws --profile "$APP_C_PROFILE" --region "$REGION" \
        vpc-lattice get-service-network-service-association \
        --service-network-service-association-identifier "$NEW_ASSOC_ID" \
        --query 'status' --output text 2>/dev/null || echo "UNKNOWN")
    echo "  new association status: $ASSOC_STATUS"
    [ "$ASSOC_STATUS" = "ACTIVE" ] || {
        echo "FAIL: new association status=$ASSOC_STATUS, expected ACTIVE" >&2; FAIL=1
    }
fi

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "reconcile: all checks passed"
    echo "  run scripts/verify.sh (APP_ID=app-c) to advance app-c to ACTIVE"
else
    echo "" >&2
    echo "reconcile: one or more checks FAILED" >&2
    exit 1
fi
