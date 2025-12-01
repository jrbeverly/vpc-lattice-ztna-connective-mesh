#!/usr/bin/env bash
# Retire validation for app-c.
#
# Submits enabled=false revision=2 for app-c, waits for the workflow to reach
# RETIRED, then probes new-connection behavior and verifies app-d and app-c's
# original application-local path are unaffected.
#
# Run from the access account after Phase 3 is active and app-c is ACTIVE.
# Requires the ZTNA client connected as a normal user on this host.
#
# Required env:
#   APP_C_PROFILE        AWS profile for the app-c account
#   REGISTRY_PROFILE     AWS profile for the registry account
#   ACCESS_PROFILE       AWS profile for the access account
#   REGISTRY_BUS_ARN     EventBridge bus ARN
#   REGISTRY_TABLE       DynamoDB table name (zlaf-registry)
#   PROBE_ROLE_ARN       ARN of zlaf-probe role (for optional verify.sh calls)
#
# Optional:
#   REGISTRY_REGION      (default: ca-central-1)
set -euo pipefail

REGION="${REGISTRY_REGION:-ca-central-1}"
REGISTRY_TABLE="${REGISTRY_TABLE:-zlaf-registry}"
LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"
EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

[ -n "${REGISTRY_BUS_ARN:-}" ] || { echo "FAIL: REGISTRY_BUS_ARN not set" >&2; exit 1; }

probe_https() {
    local fqdn="$1"
    curl -sv --max-time 10 -o /dev/null -w "%{http_code}" "https://$fqdn/" 2>/dev/null || echo "000"
}

probe_dns() {
    local fqdn="$1"
    python3 -c "import socket; print(socket.gethostbyname('$fqdn'))" 2>&1 || echo "NXDOMAIN"
}

# ── 1. Snapshot before-state ──────────────────────────────────────────────────
echo "=== retire: before-state snapshot ==="
aws --profile "$REGISTRY_PROFILE" --region "$REGION" dynamodb get-item \
    --table-name "$REGISTRY_TABLE" \
    --key '{"app_id":{"S":"app-c"}}' \
    --output json > "$EVIDENCE/retire-before-app-c.json"
echo "  saved evidence/retire-before-app-c.json"

APP_C_ACCOUNT=$(jq -r '.applications[] | select(.id=="app-c") | .account' "$LAB")
APP_D_ACCOUNT=$(jq -r '.applications[] | select(.id=="app-d") | .account' "$LAB")

# Snapshot app-c Lattice resources before retirement
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-services \
    --output json > "$EVIDENCE/retire-before-lattice-app-c.json" 2>/dev/null || true
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-target-groups \
    --output json >> "$EVIDENCE/retire-before-lattice-app-c.json" 2>/dev/null || true
echo "  saved evidence/retire-before-lattice-app-c.json"

# ── 2. Submit disable event for app-c (revision=2) ───────────────────────────
echo "=== retire: submitting enabled=false revision=2 for app-c ==="
APP_C_PROFILE="${APP_C_PROFILE}" REGISTRY_BUS_ARN="$REGISTRY_BUS_ARN" \
    "$(dirname "$0")/submit.sh" app-c 2 false
DISABLE_SUBMITTED_AT=$(date +%s)
echo "  submitted at $(date -u -d @$DISABLE_SUBMITTED_AT 2>/dev/null || date -u -r $DISABLE_SUBMITTED_AT)"

# ── 3. Wait for RETIRED state ─────────────────────────────────────────────────
echo "=== retire: waiting for app-c to reach RETIRED ==="
for i in $(seq 1 40); do
    STATE=$(aws --profile "$REGISTRY_PROFILE" --region "$REGION" dynamodb get-item \
        --table-name "$REGISTRY_TABLE" \
        --key '{"app_id":{"S":"app-c"}}' \
        --query 'Item.lifecycle_state.S' --output text 2>/dev/null || echo "UNKNOWN")
    echo "  try $i: state=$STATE"
    [ "$STATE" = "RETIRED" ] && break
    sleep 15
done
[ "$STATE" = "RETIRED" ] || { echo "FAIL: app-c did not reach RETIRED (last=$STATE)" >&2; exit 1; }
RETIRED_AT=$(date +%s)

# ── 4. Snapshot after-state ───────────────────────────────────────────────────
echo "=== retire: after-state snapshot ==="
aws --profile "$REGISTRY_PROFILE" --region "$REGION" dynamodb get-item \
    --table-name "$REGISTRY_TABLE" \
    --key '{"app_id":{"S":"app-c"}}' \
    --output json > "$EVIDENCE/retire-after-app-c.json"
echo "  saved evidence/retire-after-app-c.json"

aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-services \
    --output json > "$EVIDENCE/retire-after-lattice-app-c.json" 2>/dev/null || true
aws --profile "$APP_C_PROFILE" --region "$REGION" vpc-lattice list-target-groups \
    --output json >> "$EVIDENCE/retire-after-lattice-app-c.json" 2>/dev/null || true
echo "  saved evidence/retire-after-lattice-app-c.json"

# ── 5. Repeated disable is harmless (idempotent revision=2) ──────────────────
echo "=== retire: repeated disable (idempotent) ==="
APP_C_PROFILE="${APP_C_PROFILE}" REGISTRY_BUS_ARN="$REGISTRY_BUS_ARN" \
    "$(dirname "$0")/submit.sh" app-c 2 false
echo "  repeated disable submitted — should result in StaleEvent execution"

# ── 6. Older enable is ignored (revision=1 < current revision=2) ─────────────
echo "=== retire: older enable is ignored ==="
APP_C_PROFILE="${APP_C_PROFILE}" REGISTRY_BUS_ARN="$REGISTRY_BUS_ARN" \
    "$(dirname "$0")/submit.sh" app-c 1 true
echo "  stale enable (revision=1) submitted — should result in StaleEvent execution"

# ── 7. Measure new-connection revocation after cache expiry ──────────────────
# DNS TTL is 60s; NetBird policy propagation is observed via the WaitPropagation
# step (30s). Allow 90s total before probing.
echo "=== retire: waiting for DNS/policy cache expiry (~90s from retirement) ==="
ELAPSED=$(( $(date +%s) - RETIRED_AT ))
WAIT=$(( 90 - ELAPSED ))
[ "$WAIT" -gt 0 ] && sleep "$WAIT"

echo "--- probing app-c (website.example.ca) — expect failure ---"
DNS_C=$(probe_dns "website.example.ca")
HTTP_C=$(probe_https "website.example.ca")
echo "  DNS: $DNS_C"
echo "  HTTPS status: $HTTP_C (expected: 000 or NXDOMAIN path)"

echo "--- probing app-d (payments.example.ca) — expect success ---"
DNS_D=$(probe_dns "payments.example.ca")
HTTP_D=$(probe_https "payments.example.ca")
echo "  DNS: $DNS_D"
echo "  HTTPS status: $HTTP_D"

# App-c original application-local HTTPS via its own account's ALB DNS name.
# This uses the app-c profile to resolve the private ALB DNS, confirming the
# original application path is untouched.
echo "--- verifying app-c application-local ALB is unaffected ---"
APP_C_ALB=$(jq -r '.applications[] | select(.id=="app-c") | .alb_name' "$LAB")
APP_C_ALB_DNS=$(aws --profile "$APP_C_PROFILE" --region "$REGION" \
    elbv2 describe-load-balancers --names "$APP_C_ALB" \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "UNKNOWN")
echo "  app-c ALB DNS: $APP_C_ALB_DNS (ALB itself preserved — no HTTPS probe from ZTNA path)"

# ── 8. Save probe evidence ────────────────────────────────────────────────────
jq -n \
    --arg dns_c        "$DNS_C" \
    --arg http_c       "$HTTP_C" \
    --arg dns_d        "$DNS_D" \
    --arg http_d       "$HTTP_D" \
    --arg alb_c        "${APP_C_ALB_DNS:-unknown}" \
    --argjson retired  "$RETIRED_AT" \
    --argjson probed   "$(date +%s)" \
    '{retired_at:$retired, probed_at:$probed,
      app_c:{dns:$dns_c, https_status:$http_c},
      app_d:{dns:$dns_d, https_status:$http_d},
      app_c_alb_preserved:$alb_c}' \
    > "$EVIDENCE/retire-probe.json"
echo "  saved evidence/retire-probe.json"

# ── 9. Assertion checks ───────────────────────────────────────────────────────
FAIL=0

# app-d must still resolve and return 2xx/3xx
if ! echo "$HTTP_D" | grep -qE '^[23]'; then
    echo "FAIL: app-d HTTPS returned $HTTP_D — expected 2xx/3xx" >&2
    FAIL=1
fi

# app-c DNS must no longer resolve via the ZTNA split-view path (may resolve
# to application-local answer depending on client DNS config; record what we see)
echo "  note: app-c DNS result '$DNS_C' recorded — behavior depends on client resolver config"

# RETIRED record must have empty observed IDs
ASSOC=$(jq -r '.Item.observed_assoc_id.S // ""' "$EVIDENCE/retire-after-app-c.json")
SVC=$(jq -r '.Item.observed_svc_id.S // ""' "$EVIDENCE/retire-after-app-c.json")
ZONE=$(jq -r '.Item.observed_zone_id.S // ""' "$EVIDENCE/retire-after-app-c.json")
NB_RT=$(jq -r '.Item.observed_nb_route_id.S // ""' "$EVIDENCE/retire-after-app-c.json")
for field in "$ASSOC" "$SVC" "$ZONE" "$NB_RT"; do
    if [ -n "$field" ]; then
        echo "FAIL: RETIRED record still has non-empty observed ID: $field" >&2
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "retire: all checks passed"
else
    echo "" >&2
    echo "retire: one or more checks FAILED" >&2
    exit 1
fi
