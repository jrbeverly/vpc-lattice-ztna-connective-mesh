#!/usr/bin/env bash
# External-client probe for ZLAF publications.
#
# Run on an EC2 instance enrolled via the ZTNA client (connected as a normal
# user would be).  Performs DNS, TCP, trusted-TLS, and HTTP-response probes
# for both published FQDNs.  Writes ACTIVE to the registry only when all
# probes pass and the DynamoDB desired_revision matches the expected revision
# for that application.
#
# Required env:
#   PROBE_ROLE_ARN      ARN of zlaf-probe role in the registry account
#
# Optional env:
#   REGISTRY_TABLE        DynamoDB table (default: zlaf-registry)
#   REGISTRY_REGION       AWS region (default: ca-central-1)
#   PROBE_TIMEOUT         Per-step timeout in seconds (default: 20)
#   APPS                  Comma-separated app IDs to probe (default: app-c,app-d)
#   VERIFY_REVISION_APP_C Expected revision for app-c (must match DynamoDB if set)
#   VERIFY_REVISION_APP_D Expected revision for app-d (must match DynamoDB if set)
#
# Usage (from enrolled probe EC2, ZTNA client active):
#   PROBE_ROLE_ARN=arn:aws:iam::REGISTRY_ACCT:role/zlaf-probe scripts/verify.sh
set -euo pipefail

PROBE_ROLE_ARN="${PROBE_ROLE_ARN:?PROBE_ROLE_ARN required}"
REGISTRY_TABLE="${REGISTRY_TABLE:-zlaf-registry}"
REGION="${REGISTRY_REGION:-ca-central-1}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
APPS="${APPS:-app-c,app-d}"
LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
echo "=== ZLAF verify run=$RUN_ID ==="

fqdn_for() { jq -r ".applications[] | select(.id == \"$1\") | .fqdn" "$LAB"; }
port_for()  { jq -r ".applications[] | select(.id == \"$1\") | .port" "$LAB"; }

CREDS=$(aws sts assume-role \
    --role-arn "$PROBE_ROLE_ARN" \
    --role-session-name "zlaf-verify-$RUN_ID" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | awk '{print $1}')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | awk '{print $2}')
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | awk '{print $3}')

ddb_write() {
    local app_id="$1" lifecycle="$2" stage="$3" detail="$4" now
    now=$(date +%s)
    aws dynamodb update-item --region "$REGION" \
        --table-name "$REGISTRY_TABLE" \
        --key "{\"app_id\":{\"S\":\"$app_id\"}}" \
        --update-expression \
            "SET lifecycle_state = :s, verified_at = :t, verification_result = :r, verify_run_id = :rid" \
        --expression-attribute-values \
            "{\":s\":{\"S\":\"$lifecycle\"},\":t\":{\"N\":\"$now\"},\":r\":{\"S\":\"$stage: $detail\"},\":rid\":{\"S\":\"$RUN_ID\"}}"
}

OVERALL=0

for APP_ID in $(echo "$APPS" | tr ',' ' '); do
    FQDN=$(fqdn_for "$APP_ID")
    PORT=$(port_for "$APP_ID")
    echo ""
    echo "--- $APP_ID ($FQDN) ---"

    ENV_KEY="VERIFY_REVISION_$(echo "$APP_ID" | tr 'a-z-' 'A-Z_')"
    EXPECTED_REV="${!ENV_KEY:-}"

    RECORD=$(aws dynamodb get-item --region "$REGION" \
        --table-name "$REGISTRY_TABLE" \
        --key "{\"app_id\":{\"S\":\"$APP_ID\"}}" \
        --output json)
    CURRENT_STATE=$(echo "$RECORD" | jq -r '.Item.lifecycle_state.S // "NOT_FOUND"')
    DESIRED_REV=$(echo "$RECORD"   | jq -r '.Item.desired_revision.N // "0"')
    echo "  state=$CURRENT_STATE desired_revision=$DESIRED_REV run=$RUN_ID"

    if [ "$CURRENT_STATE" != "VERIFYING" ]; then
        echo "  SKIP: state is $CURRENT_STATE (not VERIFYING) — no write"
        continue
    fi

    if [ -n "$EXPECTED_REV" ] && [ "$EXPECTED_REV" != "$DESIRED_REV" ]; then
        echo "  FAIL: revision_mismatch expected=$EXPECTED_REV current=$DESIRED_REV"
        ddb_write "$APP_ID" "FAILED" "revision_mismatch" \
            "expected=$EXPECTED_REV current=$DESIRED_REV run=$RUN_ID"
        OVERALL=1
        continue
    fi

    FAIL=0

    # 1. DNS — FQDN must resolve via the ZTNA domain route → endpoint
    RESOLVED=$(python3 -c "import socket; print(socket.gethostbyname('$FQDN'))" 2>&1) || {
        echo "  FAIL dns: $FQDN — $RESOLVED"
        ddb_write "$APP_ID" "FAILED" "dns" "$RESOLVED run=$RUN_ID rev=$DESIRED_REV"
        OVERALL=1; FAIL=1
    }
    [ "$FAIL" -eq 0 ] && echo "  dns ok: $FQDN → $RESOLVED"

    # 2. TCP — port must be reachable on the resolved address
    if [ "$FAIL" -eq 0 ]; then
        if ! python3 -c "
import socket, sys
s = socket.socket()
s.settimeout($PROBE_TIMEOUT)
try:
    s.connect(('$FQDN', $PORT))
    s.close()
except Exception as e:
    sys.exit(str(e))
" 2>/tmp/zlaf-probe-"$APP_ID".tcp; then
            TCP_ERR=$(cat /tmp/zlaf-probe-"$APP_ID".tcp 2>/dev/null || echo "connection refused")
            echo "  FAIL tcp: $FQDN:$PORT — $TCP_ERR"
            ddb_write "$APP_ID" "FAILED" "tcp" "$TCP_ERR run=$RUN_ID rev=$DESIRED_REV"
            OVERALL=1; FAIL=1
        else
            echo "  tcp ok: $FQDN:$PORT"
        fi
    fi

    # 3. Trusted TLS + known-response
    #    curl validates the cert chain and hostname by default (no --insecure).
    #    A 2xx–5xx HTTP status means the application backend responded.
    if [ "$FAIL" -eq 0 ]; then
        HTTP_CODE=$(curl --max-time "$PROBE_TIMEOUT" \
            -o /tmp/zlaf-probe-"$APP_ID".body \
            -w "%{http_code}" \
            --silent \
            "https://$FQDN/" \
            2>/tmp/zlaf-probe-"$APP_ID".tls) || HTTP_CODE="CURLERR"

        if [ "$HTTP_CODE" = "CURLERR" ]; then
            TLS_ERR=$(tail -1 /tmp/zlaf-probe-"$APP_ID".tls 2>/dev/null || echo "curl failed")
            echo "  FAIL tls: $TLS_ERR"
            ddb_write "$APP_ID" "FAILED" "tls" "$TLS_ERR run=$RUN_ID rev=$DESIRED_REV"
            OVERALL=1; FAIL=1
        elif ! echo "$HTTP_CODE" | grep -qE '^[2-5][0-9][0-9]$'; then
            echo "  FAIL response: http_code=$HTTP_CODE"
            ddb_write "$APP_ID" "FAILED" "response" \
                "http_code=$HTTP_CODE run=$RUN_ID rev=$DESIRED_REV"
            OVERALL=1; FAIL=1
        else
            BODY_LEN=$(wc -c < /tmp/zlaf-probe-"$APP_ID".body 2>/dev/null || echo 0)
            echo "  tls ok: trusted cert, http_code=$HTTP_CODE body_bytes=$BODY_LEN"
        fi
    fi

    if [ "$FAIL" -eq 0 ]; then
        echo "  PASS → ACTIVE r$DESIRED_REV"
        ddb_write "$APP_ID" "ACTIVE" "pass" \
            "dns=$RESOLVED http=$HTTP_CODE body=$BODY_LEN run=$RUN_ID rev=$DESIRED_REV"
    fi
done

echo ""
[ "$OVERALL" -eq 0 ] && echo "=== verify PASS run=$RUN_ID ===" \
    || { echo "=== verify FAIL run=$RUN_ID ===" >&2; exit 1; }
