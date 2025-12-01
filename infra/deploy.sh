#!/usr/bin/env bash
# Packages controller.py and deploys the control-plane CloudFormation stack.
#
# Prerequisites:
#   - aws CLI authenticated to the REGISTRY account
#   - evidence/resources.json present (written by scripts/access-up.sh)
#   - NB_SECRET_ARN set to the Secrets Manager secret ARN for the NetBird token
#   - REGISTRY_PROFILE set to the registry account AWS profile (default: registry)
#
# Usage:
#   NB_SECRET_ARN=arn:aws:secretsmanager:... REGISTRY_PROFILE=registry infra/deploy.sh
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$BASE/lab.json"
RES="$BASE/evidence/resources.json"
INFRA="$BASE/infra"

[ -f "$RES" ] || { echo "FAIL: evidence/resources.json not found — run scripts/access-up.sh first" >&2; exit 1; }
[ -n "${NB_SECRET_ARN:-}" ] || { echo "FAIL: NB_SECRET_ARN is not set" >&2; exit 1; }

REGISTRY_PROFILE="${REGISTRY_PROFILE:-registry}"
REGION=$(jq -r .region "$LAB")
REGISTRY_ACCOUNT=$(aws --profile "$REGISTRY_PROFILE" sts get-caller-identity --query Account --output text)

# ── Package Lambda ────────────────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp "$BASE/controller.py" "$TMPDIR/controller.py"
ZIPFILE="$TMPDIR/zlaf-controller.zip"
(cd "$TMPDIR" && zip "$ZIPFILE" controller.py)

CODE_BUCKET="zlaf-deploy-$REGISTRY_ACCOUNT-$REGION"
aws --profile "$REGISTRY_PROFILE" s3 mb "s3://$CODE_BUCKET" --region "$REGION" 2>/dev/null || true
aws --profile "$REGISTRY_PROFILE" s3 cp "$ZIPFILE" "s3://$CODE_BUCKET/zlaf-controller.zip"

# ── Read access cell outputs from resources.json ──────────────────────────────
SN_ARN=$(jq -r .service_network_arn "$RES")
VPC_ID=$(jq -r .vpc               "$RES")
EP_ID=$(jq -r .endpoint           "$RES")
EP_SUB=$(jq -r .ep_subnet         "$RES")
NB_PEER=$(jq -r .nb_peer          "$RES")

APP_C=$(jq -r .accounts.app_c   "$LAB")
APP_D=$(jq -r .accounts.app_d   "$LAB")
ACCESS=$(jq -r .accounts.access "$LAB")
NB_URL=$(jq -r .netbird.management_url "$LAB")

STACK=zlaf-control-plane

aws --profile "$REGISTRY_PROFILE" --region "$REGION" cloudformation deploy \
    --stack-name    "$STACK" \
    --template-file "$INFRA/control-plane.yaml" \
    --capabilities  CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        AppCAccountId="$APP_C" \
        AppDAccountId="$APP_D" \
        AccessAccountId="$ACCESS" \
        ServiceNetworkArn="$SN_ARN" \
        AccessVpcId="$VPC_ID" \
        EndpointId="$EP_ID" \
        EpSubnetId="$EP_SUB" \
        NbPeerId="$NB_PEER" \
        NbManagementUrl="$NB_URL" \
        NbSecretArn="$NB_SECRET_ARN" \
        CodeBucket="$CODE_BUCKET" \
        CodeKey=zlaf-controller.zip

echo ""
echo "Stack deployed. Outputs:"
aws --profile "$REGISTRY_PROFILE" --region "$REGION" cloudformation describe-stacks \
    --stack-name "$STACK" \
    --query "Stacks[0].Outputs" \
    --output table
