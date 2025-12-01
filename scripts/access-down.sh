#!/usr/bin/env bash
# Tears down all experiment-owned resources created by access-up.sh.
#
# Preserved (not touched):
#   Accounts C/D, their VPCs, ALBs, ACM certificates, Route 53 records
#
# Requires: NETBIRD_API_TOKEN
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"
EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
RESOURCES="$EVIDENCE/resources.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$RESOURCES" ] || fail "evidence/resources.json not found; run access-up.sh first"
[ -n "${NETBIRD_API_TOKEN:-}" ] || fail "NETBIRD_API_TOKEN is not set"

REGION=$(jq -r .region "$LAB")
PEER_ROLE=$(jq -r .access_cell.peer_iam_role "$LAB")
NB_MGMT=$(jq -r .netbird.management_url "$LAB")
NB_AUTH="Authorization: Token $NETBIRD_API_TOKEN"

VPC_ID=$(jq -r .vpc              "$RESOURCES")
IGW_ID=$(jq -r .igw              "$RESOURCES")
EP_SUBNET_ID=$(jq -r .ep_subnet  "$RESOURCES")
PEER_SUBNET_ID=$(jq -r .peer_subnet "$RESOURCES")
PEER_RTB_ID=$(jq -r .peer_rtb    "$RESOURCES")
EP_SG_ID=$(jq -r .ep_sg          "$RESOURCES")
PEER_SG_ID=$(jq -r .peer_sg      "$RESOURCES")
SN_ARN=$(jq -r .service_network_arn "$RESOURCES")
ENDPOINT_ID=$(jq -r .endpoint    "$RESOURCES")
SHARE_ARN=$(jq -r .ram_share_arn "$RESOURCES")
INSTANCE_ID=$(jq -r .peer_instance "$RESOURCES")
NB_PEER_ID=$(jq -r .nb_peer      "$RESOURCES")
NB_ROUTE_ID=$(jq -r .nb_route    "$RESOURCES")
NB_POLICY_ID=$(jq -r .nb_policy  "$RESOURCES")
NB_GROUP_ID=$(jq -r .nb_group    "$RESOURCES")
NB_PEER_GROUP_ID=$(jq -r .nb_peer_group "$RESOURCES")
NB_DENY_GROUP_ID=$(jq -r .nb_deny_group "$RESOURCES")
NB_NS_ID=$(jq -r .nb_ns          "$RESOURCES")

echo "=== 1. NetBird: nameserver / route / policy / groups / peer ==="

curl -sf -X DELETE "$NB_MGMT/api/dns/nameservers/$NB_NS_ID" -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/routes/$NB_ROUTE_ID"       -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/policies/$NB_POLICY_ID"    -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/peers/$NB_PEER_ID"         -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/groups/$NB_PEER_GROUP_ID"  -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/groups/$NB_DENY_GROUP_ID"  -H "$NB_AUTH" > /dev/null 2>&1 || true
curl -sf -X DELETE "$NB_MGMT/api/groups/$NB_GROUP_ID"       -H "$NB_AUTH" > /dev/null 2>&1 || true
echo "  NetBird objects removed"

echo "=== 2. RAM share ==="

aws ram delete-resource-share \
  --region "$REGION" --resource-share-arn "$SHARE_ARN" > /dev/null 2>&1 || true
echo "  RAM share $SHARE_ARN deleted"

echo "=== 3. VPC endpoint ==="

aws ec2 delete-vpc-endpoints \
  --region "$REGION" --vpc-endpoint-ids "$ENDPOINT_ID" > /dev/null
echo "  endpoint $ENDPOINT_ID deleted"

echo "=== 4. Service network ==="

# Extract service network ID from ARN (last path segment)
SN_ID=$(echo "$SN_ARN" | awk -F'/' '{print $NF}')
aws vpc-lattice delete-service-network \
  --region "$REGION" --service-network-identifier "$SN_ID" > /dev/null 2>&1 || true
echo "  service network $SN_ID deleted"

echo "=== 5. EC2 peer instance ==="

aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "  instance $INSTANCE_ID terminated"

echo "=== 6. IAM role and instance profile ==="

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PEER_ROLE" --role-name "$PEER_ROLE" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$PEER_ROLE" 2>/dev/null || true
aws iam detach-role-policy \
  --role-name "$PEER_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
aws iam delete-role-policy --role-name "$PEER_ROLE" --policy-name zlaf-peer-secrets 2>/dev/null || true
aws iam delete-role --role-name "$PEER_ROLE" 2>/dev/null || true
echo "  IAM role $PEER_ROLE deleted"

echo "=== 7. Security groups ==="

aws ec2 delete-security-group --region "$REGION" --group-id "$PEER_SG_ID" 2>/dev/null || true
aws ec2 delete-security-group --region "$REGION" --group-id "$EP_SG_ID"   2>/dev/null || true
echo "  security groups deleted"

echo "=== 8. Subnets and route table ==="

aws ec2 disassociate-route-table --region "$REGION" \
  --association-id "$(aws ec2 describe-route-tables \
    --region "$REGION" --route-table-ids "$PEER_RTB_ID" \
    --query 'RouteTables[0].Associations[?!Main][0].RouteTableAssociationId' \
    --output text)" 2>/dev/null || true
aws ec2 delete-route-table --region "$REGION" --route-table-id "$PEER_RTB_ID" 2>/dev/null || true
aws ec2 delete-subnet --region "$REGION" --subnet-id "$PEER_SUBNET_ID" 2>/dev/null || true
aws ec2 delete-subnet --region "$REGION" --subnet-id "$EP_SUBNET_ID"   2>/dev/null || true
echo "  subnets and route table deleted"

echo "=== 9. Internet gateway ==="

aws ec2 detach-internet-gateway \
  --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
aws ec2 delete-internet-gateway \
  --region "$REGION" --internet-gateway-id "$IGW_ID" 2>/dev/null || true
echo "  IGW $IGW_ID deleted"

echo "=== 10. VPC ==="

aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
echo "  VPC $VPC_ID deleted"

echo
echo "Teardown complete. ALBs, certificates, and application DNS preserved."
