#!/usr/bin/env bash
# Creates the ZLAF access cell: access VPC, service network, ServiceNetwork-type
# VPC endpoint, NetBird routing peer, and RAM share with application accounts.
#
# Requires:
#   NETBIRD_API_TOKEN   NetBird management API token
#   APP_C_PROFILE       AWS profile for account C  (default: app-c)
#   APP_D_PROFILE       AWS profile for account D  (default: app-d)
#
# Fixtures (not created or deleted by this experiment):
#   accounts C and D, their VPCs, ALBs, certificates, and private DNS
#
# Experiment-owned resources (deleted by access-down.sh):
#   access VPC and all contents, service network, VPC endpoint, RAM share,
#   IAM role/profile, NetBird peer + route + policy + groups
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)/lab.json"
EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

fail()    { echo "FAIL: $*"    >&2; exit 1; }
blocker() { echo "BLOCKER: $*" >&2; exit 1; }

command -v jq   >/dev/null || fail "jq is required"
command -v aws  >/dev/null || fail "aws CLI is required"
command -v curl >/dev/null || fail "curl is required"

REGION=$(jq -r .region "$LAB")

ACCOUNT_ACCESS=$(jq -r .accounts.access    "$LAB")
ACCOUNT_C=$(jq -r .accounts.app_c          "$LAB")
ACCOUNT_D=$(jq -r .accounts.app_d          "$LAB")

PROFILE_C="${APP_C_PROFILE:-app-c}"
PROFILE_D="${APP_D_PROFILE:-app-d}"

VPC_NAME=$(jq -r .access_cell.vpc_name              "$LAB")
VPC_CIDR=$(jq -r .access_cell.vpc_cidr              "$LAB")
EP_SUBNET_NAME=$(jq -r .access_cell.endpoint_subnet_name "$LAB")
EP_SUBNET_CIDR=$(jq -r .access_cell.endpoint_subnet_cidr "$LAB")
PEER_SUBNET_NAME=$(jq -r .access_cell.peer_subnet_name   "$LAB")
PEER_SUBNET_CIDR=$(jq -r .access_cell.peer_subnet_cidr   "$LAB")
EP_SG_NAME=$(jq -r .access_cell.endpoint_sg_name    "$LAB")
PEER_SG_NAME=$(jq -r .access_cell.peer_sg_name      "$LAB")
SN_NAME=$(jq -r .access_cell.service_network_name   "$LAB")
RAM_SHARE_NAME=$(jq -r .access_cell.ram_share_name  "$LAB")
PEER_ROLE=$(jq -r .access_cell.peer_iam_role         "$LAB")
PEER_NAME=$(jq -r .access_cell.peer_instance_name   "$LAB")
PEER_TYPE=$(jq -r .access_cell.peer_instance_type   "$LAB")
PEER_AMI_PARAM=$(jq -r .access_cell.peer_ami_param  "$LAB")
PEER_SECRET=$(jq -r .access_cell.peer_secret_name   "$LAB")

ALB_C=$(jq -r '.applications[0].alb_name' "$LAB")
CIDR_C=$(jq -r '.applications[0].vpc_cidr' "$LAB")
ALB_D=$(jq -r '.applications[1].alb_name' "$LAB")
CIDR_D=$(jq -r '.applications[1].vpc_cidr' "$LAB")

NB_MGMT=$(jq -r .netbird.management_url "$LAB")
NB_VERSION=$(jq -r .netbird.version     "$LAB")
NB_GROUP=$(jq -r .netbird.group_name    "$LAB")
NB_PEER_NAME=$(jq -r .netbird.peer_name "$LAB")
NB_DNS_DOMAIN=$(jq -r .netbird.dns_domain "$LAB")

VPC_DNS=$(echo "$VPC_CIDR" | awk -F'[./]' '{print $1"."$2"."$3".2"}')

[ -n "${NETBIRD_API_TOKEN:-}" ] || blocker "NETBIRD_API_TOKEN is not set"

echo "=== 1. Account identity ==="

aws sts get-caller-identity --region "$REGION" \
  > "$EVIDENCE/01-access-identity.json"

aws sts get-caller-identity --profile "$PROFILE_C" --region "$REGION" \
  > "$EVIDENCE/01-app-c-identity.json" \
  2>/dev/null || blocker "profile $PROFILE_C not configured or not authenticated"
aws sts get-caller-identity --profile "$PROFILE_D" --region "$REGION" \
  > "$EVIDENCE/01-app-d-identity.json" \
  2>/dev/null || blocker "profile $PROFILE_D not configured or not authenticated"

C_ACTUAL=$(jq -r .Account "$EVIDENCE/01-app-c-identity.json")
D_ACTUAL=$(jq -r .Account "$EVIDENCE/01-app-d-identity.json")
[ "$C_ACTUAL" = "$ACCOUNT_C" ] || fail "app-c account: expected $ACCOUNT_C got $C_ACTUAL"
[ "$D_ACTUAL" = "$ACCOUNT_D" ] || fail "app-d account: expected $ACCOUNT_D got $D_ACTUAL"
echo "  access, app-c, app-d verified"

echo "=== 2. Application ALBs, listeners, and certificates ==="

for label in c d; do
  if [ "$label" = c ]; then PROF=$PROFILE_C; ALB=$ALB_C; else PROF=$PROFILE_D; ALB=$ALB_D; fi

  aws elbv2 describe-load-balancers \
    --profile "$PROF" --region "$REGION" --names "$ALB" \
    > "$EVIDENCE/02-alb-$label.json" \
    || fail "ALB $ALB not found (app-$label)"

  SCHEME=$(jq -r '.LoadBalancers[0].Scheme' "$EVIDENCE/02-alb-$label.json")
  [ "$SCHEME" = "internal" ] || fail "ALB $ALB (app-$label) has scheme '$SCHEME', expected internal"

  ALB_ARN=$(jq -r '.LoadBalancers[0].LoadBalancerArn' "$EVIDENCE/02-alb-$label.json")
  aws elbv2 describe-listeners \
    --profile "$PROF" --region "$REGION" --load-balancer-arn "$ALB_ARN" \
    > "$EVIDENCE/02-listeners-$label.json"

  HTTPS_COUNT=$(jq '[.Listeners[] | select(.Protocol=="HTTPS" and .Port==443)] | length' \
    "$EVIDENCE/02-listeners-$label.json")
  [ "$HTTPS_COUNT" -ge 1 ] || fail "ALB $ALB (app-$label) has no HTTPS/443 listener"

  CERT_ARN=$(jq -r '[.Listeners[] | select(.Protocol=="HTTPS" and .Port==443)][0].Certificates[0].CertificateArn' \
    "$EVIDENCE/02-listeners-$label.json")
  aws acm describe-certificate \
    --profile "$PROF" --region "$REGION" --certificate-arn "$CERT_ARN" \
    > "$EVIDENCE/02-cert-$label.json" \
    || fail "certificate $CERT_ARN not found (app-$label)"

  echo "  app-$label: $ALB internal HTTPS/443, cert $CERT_ARN"
done

echo "=== 3. VPC CIDRs and route/attachment inventory ==="

[ "$CIDR_C" = "$CIDR_D" ] || fail "VPC CIDRs do not match: $CIDR_C vs $CIDR_D"
echo "  CIDRs match: $CIDR_C = $CIDR_D (overlapping CIDR confirmed)"

for label in c d; do
  if [ "$label" = c ]; then PROF=$PROFILE_C; CIDR=$CIDR_C; else PROF=$PROFILE_D; CIDR=$CIDR_D; fi

  VPC_ID=$(aws ec2 describe-vpcs \
    --profile "$PROF" --region "$REGION" \
    --filters "Name=cidr,Values=$CIDR" \
    --query 'Vpcs[0].VpcId' --output text)
  [ -n "$VPC_ID" ] && [ "$VPC_ID" != None ] || fail "no VPC with CIDR $CIDR in app-$label"

  aws ec2 describe-vpc-peering-connections \
    --profile "$PROF" --region "$REGION" \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" \
    > "$EVIDENCE/03-peering-req-$label.json"
  aws ec2 describe-vpc-peering-connections \
    --profile "$PROF" --region "$REGION" \
    --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC_ID" \
    >> "$EVIDENCE/03-peering-req-$label.json"

  aws ec2 describe-transit-gateway-attachments \
    --profile "$PROF" --region "$REGION" \
    --filters "Name=resource-id,Values=$VPC_ID" \
    > "$EVIDENCE/03-tgw-$label.json"

  PEERING_COUNT=$(jq '[.VpcPeeringConnections // [] | .[] | select(.Status.Code!="deleted")] | length' \
    "$EVIDENCE/03-peering-req-$label.json" 2>/dev/null || echo 0)
  TGW_COUNT=$(jq '.TransitGatewayAttachments | length' "$EVIDENCE/03-tgw-$label.json")
  echo "  app-$label: VPC $VPC_ID  peering=$PEERING_COUNT  TGW=$TGW_COUNT"
done

echo "=== 4. NetBird setup key secret ==="

aws secretsmanager describe-secret \
  --region "$REGION" --secret-id "$PEER_SECRET" \
  > "$EVIDENCE/04-peer-secret.json" \
  || blocker "Secrets Manager secret $PEER_SECRET not found — create it with key 'setup_key' before running"
echo "  secret $PEER_SECRET exists"

echo "=== 5. Access VPC ==="

VPC_ID=$(aws ec2 create-vpc \
  --region "$REGION" \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support
echo "  VPC $VPC_ID ($VPC_CIDR)"

IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$VPC_NAME}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

EP_SUBNET_ID=$(aws ec2 create-subnet \
  --region "$REGION" --vpc-id "$VPC_ID" \
  --cidr-block "$EP_SUBNET_CIDR" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$EP_SUBNET_NAME}]" \
  --query 'Subnet.SubnetId' --output text)

PEER_SUBNET_ID=$(aws ec2 create-subnet \
  --region "$REGION" --vpc-id "$VPC_ID" \
  --cidr-block "$PEER_SUBNET_CIDR" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PEER_SUBNET_NAME}]" \
  --query 'Subnet.SubnetId' --output text)

PEER_RTB_ID=$(aws ec2 create-route-table \
  --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PEER_SUBNET_NAME}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$REGION" \
  --route-table-id "$PEER_RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
aws ec2 associate-route-table --region "$REGION" \
  --subnet-id "$PEER_SUBNET_ID" --route-table-id "$PEER_RTB_ID" > /dev/null

echo "  subnets: endpoint=$EP_SUBNET_ID peer=$PEER_SUBNET_ID (peer has IGW route)"

echo "=== 6. Security groups ==="

EP_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "$EP_SG_NAME" --description "zlaf service-network endpoint" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$EP_SG_NAME}]" \
  --query 'GroupId' --output text)
# Inbound: HTTPS from VPC CIDR (Lattice traffic from routing peer)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$EP_SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$VPC_CIDR\"}]}]" > /dev/null
# Outbound: remove default all-egress; restrict to VPC only
aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$EP_SG_ID" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' > /dev/null 2>&1 || true
aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$EP_SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$VPC_CIDR\"}]}]" > /dev/null

PEER_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "$PEER_SG_NAME" --description "zlaf NetBird routing peer" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PEER_SG_NAME}]" \
  --query 'GroupId' --output text)
# Inbound: WireGuard
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$PEER_SG_ID" \
  --ip-permissions '[{"IpProtocol":"udp","FromPort":51820,"ToPort":51820,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' > /dev/null
# Outbound: restricted to NetBird control plane + STUN/TURN + VPC DNS; NOT application CIDRs
aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$PEER_SG_ID" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' > /dev/null 2>&1 || true
aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$PEER_SG_ID" \
  --ip-permissions "[
    {\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"0.0.0.0/0\",\"Description\":\"NetBird mgmt+TURN HTTPS\"}]},
    {\"IpProtocol\":\"udp\",\"FromPort\":3478,\"ToPort\":3478,\"IpRanges\":[{\"CidrIp\":\"0.0.0.0/0\",\"Description\":\"STUN\"}]},
    {\"IpProtocol\":\"udp\",\"FromPort\":51820,\"ToPort\":51820,\"IpRanges\":[{\"CidrIp\":\"0.0.0.0/0\",\"Description\":\"WireGuard\"}]},
    {\"IpProtocol\":\"udp\",\"FromPort\":53,\"ToPort\":53,\"IpRanges\":[{\"CidrIp\":\"$VPC_CIDR\",\"Description\":\"VPC DNS\"}]},
    {\"IpProtocol\":\"tcp\",\"FromPort\":53,\"ToPort\":53,\"IpRanges\":[{\"CidrIp\":\"$VPC_CIDR\",\"Description\":\"VPC DNS\"}]},
    {\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[{\"GroupId\":\"$EP_SG_ID\",\"Description\":\"service-network endpoint\"}]}
  ]" > /dev/null

aws ec2 describe-security-groups --region "$REGION" \
  --group-ids "$EP_SG_ID" "$PEER_SG_ID" > "$EVIDENCE/06-security-groups.json"
echo "  endpoint SG: $EP_SG_ID  peer SG: $PEER_SG_ID"

echo "=== 7. VPC Lattice service network ==="

SN_ARN=$(aws vpc-lattice create-service-network \
  --region "$REGION" \
  --name "$SN_NAME" \
  --auth-type NONE \
  --query 'arn' --output text)
echo "  service network: $SN_ARN"

# ServiceNetwork-type VPC endpoint (verify: aws ec2 create-vpc-endpoint --vpc-endpoint-type ServiceNetwork)
ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --region "$REGION" \
  --vpc-endpoint-type ServiceNetwork \
  --service-network-arn "$SN_ARN" \
  --vpc-id "$VPC_ID" \
  --subnet-ids "$EP_SUBNET_ID" \
  --security-group-ids "$EP_SG_ID" \
  --query 'VpcEndpoint.VpcEndpointId' --output text)
echo "  endpoint: $ENDPOINT_ID"

aws ec2 describe-vpc-endpoints \
  --region "$REGION" --vpc-endpoint-ids "$ENDPOINT_ID" \
  > "$EVIDENCE/07-endpoint.json"

echo "=== 8. RAM share with application accounts ==="

SHARE_ARN=$(aws ram create-resource-share \
  --region "$REGION" \
  --name "$RAM_SHARE_NAME" \
  --resource-arns "$SN_ARN" \
  --principals "$ACCOUNT_C" "$ACCOUNT_D" \
  --allow-external-principals \
  --query 'resourceShare.resourceShareArn' --output text)

aws ram get-resource-share-resources \
  --region "$REGION" --resource-share-arns "$SHARE_ARN" \
  --resource-type "vpc-lattice:ServiceNetwork" \
  > "$EVIDENCE/08-ram-share.json"

# Accept invitations in each application account if not in same AWS Organization
sleep 5
for pair in "$PROFILE_C:app-c" "$PROFILE_D:app-d"; do
  PROF=${pair%%:*}; LABEL=${pair#*:}
  INVITE=$(aws ram get-resource-share-invitations \
    --profile "$PROF" --region "$REGION" \
    --resource-share-arns "$SHARE_ARN" \
    --query 'resourceShareInvitations[?status==`PENDING`][0].resourceShareInvitationArn' \
    --output text 2>/dev/null || echo None)
  if [ -n "$INVITE" ] && [ "$INVITE" != None ]; then
    aws ram accept-resource-share-invitation \
      --profile "$PROF" --region "$REGION" \
      --resource-share-invitation-arn "$INVITE" > /dev/null
    echo "  $LABEL: invitation accepted"
  else
    echo "  $LABEL: no pending invitation (may be auto-accepted via Organizations)"
  fi
done

aws ram list-principals \
  --region "$REGION" --resource-share-arns "$SHARE_ARN" \
  > "$EVIDENCE/08-ram-principals.json"
echo "  share $SHARE_ARN → $ACCOUNT_C, $ACCOUNT_D"

echo "=== 9. IAM role for routing peer ==="

TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role \
  --role-name "$PEER_ROLE" \
  --assume-role-policy-document "$TRUST_POLICY" > /dev/null
aws iam attach-role-policy \
  --role-name "$PEER_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam put-role-policy \
  --role-name "$PEER_ROLE" \
  --policy-name zlaf-peer-secrets \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:${REGION}:${ACCOUNT_ACCESS}:secret:${PEER_SECRET}*\"}]}"
aws iam create-instance-profile --instance-profile-name "$PEER_ROLE" > /dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PEER_ROLE" --role-name "$PEER_ROLE"
# instance profile propagation
sleep 10

echo "=== 10. NetBird routing peer EC2 ==="

AMI_ID=$(aws ssm get-parameter \
  --region "$REGION" --name "$PEER_AMI_PARAM" \
  --query 'Parameter.Value' --output text)

USER_DATA=$(base64 -w0 <<USERDATA
#!/bin/bash
set -e
yum install -y jq
curl -fsSL https://pkgs.netbird.io/install.sh | NETBIRD_VERSION=${NB_VERSION} bash
SETUP_KEY=\$(aws secretsmanager get-secret-value \
  --region ${REGION} --secret-id ${PEER_SECRET} \
  --query SecretString --output text | jq -r .setup_key)
netbird up \
  --management-url ${NB_MGMT} \
  --setup-key "\$SETUP_KEY" \
  --hostname ${NB_PEER_NAME}
USERDATA
)

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$PEER_TYPE" \
  --subnet-id "$PEER_SUBNET_ID" \
  --security-group-ids "$PEER_SG_ID" \
  --iam-instance-profile "Name=$PEER_ROLE" \
  --associate-public-ip-address \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PEER_NAME},{Key=ManagedBy,Value=ZLAF},{Key=Component,Value=RoutingPeer}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "  instance $INSTANCE_ID launched"

# Wait for SSM registration (NetBird enrollment happens in background)
echo "  waiting for SSM Online..."
while true; do
  PING=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo Offline)
  [ "$PING" = Online ] && break
  sleep 15
done
aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  > "$EVIDENCE/10-peer-instance.json"
echo "  peer SSM Online"

echo "=== 11. NetBird configuration ==="

NB_AUTH="Authorization: Token $NETBIRD_API_TOKEN"

# Verify peer enrolled
sleep 30  # allow user data to complete enrollment
NB_PEER_ID=$(curl -sf "$NB_MGMT/api/peers" -H "$NB_AUTH" \
  | jq -r ".[] | select(.name==\"$NB_PEER_NAME\") | .id")
[ -n "$NB_PEER_ID" ] || fail "NetBird peer $NB_PEER_NAME not found; check setup key and user data"
echo "  peer enrolled: $NB_PEER_ID"

# Create authorized access group
NB_GROUP_RESPONSE=$(curl -sf -X POST "$NB_MGMT/api/groups" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d "{\"name\":\"$NB_GROUP\"}")
NB_GROUP_ID=$(echo "$NB_GROUP_RESPONSE" | jq -r .id)

# Add routing peer to its own group for policy targeting
NB_PEER_GROUP_RESPONSE=$(curl -sf -X POST "$NB_MGMT/api/groups" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d "{\"name\":\"zlaf-routing-peer\",\"peers\":[{\"id\":\"$NB_PEER_ID\"}]}")
NB_PEER_GROUP_ID=$(echo "$NB_PEER_GROUP_RESPONSE" | jq -r .id)

# Denied identity group (explicitly excluded from routing access)
NB_DENY_GROUP_RESPONSE=$(curl -sf -X POST "$NB_MGMT/api/groups" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"name":"zlaf-denied"}')
NB_DENY_GROUP_ID=$(echo "$NB_DENY_GROUP_RESPONSE" | jq -r .id)
echo "  groups: access=$NB_GROUP_ID peer=$NB_PEER_GROUP_ID denied=$NB_DENY_GROUP_ID"

# Access policy: deny zlaf-denied, allow zlaf-access (TCP only); no default broad allow
NB_POLICY=$(curl -sf -X POST "$NB_MGMT/api/policies" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d "{
    \"name\":\"zlaf-access-only\",
    \"enabled\":true,
    \"rules\":[
      {
        \"name\":\"deny-excluded\",
        \"enabled\":true,
        \"action\":\"drop\",
        \"bidirectional\":false,
        \"protocol\":\"all\",
        \"sources\":[{\"id\":\"$NB_DENY_GROUP_ID\"}],
        \"destinations\":[{\"id\":\"$NB_PEER_GROUP_ID\"}]
      },
      {
        \"name\":\"allow-zlaf-access-tcp\",
        \"enabled\":true,
        \"action\":\"accept\",
        \"bidirectional\":false,
        \"protocol\":\"tcp\",
        \"sources\":[{\"id\":\"$NB_GROUP_ID\"}],
        \"destinations\":[{\"id\":\"$NB_PEER_GROUP_ID\"}]
      }
    ]
  }")
NB_POLICY_ID=$(echo "$NB_POLICY" | jq -r .id)
echo "  policy: $NB_POLICY_ID"

# Routing peer: route endpoint subnet through peer; peer uses VPC DNS resolver
NB_ROUTE=$(curl -sf -X POST "$NB_MGMT/api/routes" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d "{
    \"description\":\"zlaf service-network endpoint subnet\",
    \"network_id\":\"zlaf-access-cell\",
    \"network\":\"$EP_SUBNET_CIDR\",
    \"peer\":\"$NB_PEER_ID\",
    \"enabled\":true,
    \"masquerade\":false,
    \"metric\":9999,
    \"groups\":[\"$NB_GROUP_ID\"]
  }")
NB_ROUTE_ID=$(echo "$NB_ROUTE" | jq -r .id)

# DNS forwarder: resolve application domain via VPC resolver
NB_NS=$(curl -sf -X POST "$NB_MGMT/api/dns/nameservers" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d "{
    \"name\":\"zlaf-vpc-resolver\",
    \"description\":\"VPC Route 53 resolver for ZLAF access cell\",
    \"nameservers\":[{\"ip\":\"$VPC_DNS\",\"ns_type\":\"udp\",\"port\":53}],
    \"groups\":[\"$NB_GROUP_ID\"],
    \"domains\":[\"$NB_DNS_DOMAIN\"],
    \"enabled\":true,
    \"primary\":false
  }")
NB_NS_ID=$(echo "$NB_NS" | jq -r .id)
echo "  route $NB_ROUTE_ID  dns-nameserver $NB_NS_ID  resolver $VPC_DNS"

# Capture NetBird state
curl -sf "$NB_MGMT/api/peers"    -H "$NB_AUTH" > "$EVIDENCE/11-nb-peers.json"
curl -sf "$NB_MGMT/api/routes"   -H "$NB_AUTH" > "$EVIDENCE/11-nb-routes.json"
curl -sf "$NB_MGMT/api/policies" -H "$NB_AUTH" > "$EVIDENCE/11-nb-policies.json"
curl -sf "$NB_MGMT/api/groups"   -H "$NB_AUTH" > "$EVIDENCE/11-nb-groups.json"

echo "=== 12. Verification: no applications published ==="

for label in c d; do
  if [ "$label" = c ]; then PROF=$PROFILE_C; else PROF=$PROFILE_D; fi
  SVC_COUNT=$(aws vpc-lattice list-services \
    --profile "$PROF" --region "$REGION" \
    --query 'length(items)' --output text 2>/dev/null || echo 0)
  echo "  app-$label: $SVC_COUNT Lattice services (expect 0 or only pre-existing)"
done

aws vpc-lattice list-service-network-service-associations \
  --region "$REGION" --service-network-identifier "$SN_ARN" \
  > "$EVIDENCE/12-no-services.json"
ASSOC_COUNT=$(jq '.items | length' "$EVIDENCE/12-no-services.json")
[ "$ASSOC_COUNT" = 0 ] || echo "  WARNING: $ASSOC_COUNT service associations already exist"
echo "  service network has $ASSOC_COUNT service associations"

# Record resource IDs for teardown
jq -n \
  --arg vpc        "$VPC_ID" \
  --arg igw        "$IGW_ID" \
  --arg ep_subnet  "$EP_SUBNET_ID" \
  --arg pr_subnet  "$PEER_SUBNET_ID" \
  --arg pr_rtb     "$PEER_RTB_ID" \
  --arg ep_sg      "$EP_SG_ID" \
  --arg peer_sg    "$PEER_SG_ID" \
  --arg sn_arn     "$SN_ARN" \
  --arg endpoint   "$ENDPOINT_ID" \
  --arg share_arn  "$SHARE_ARN" \
  --arg instance   "$INSTANCE_ID" \
  --arg nb_peer    "$NB_PEER_ID" \
  --arg nb_route   "$NB_ROUTE_ID" \
  --arg nb_policy  "$NB_POLICY_ID" \
  --arg nb_group   "$NB_GROUP_ID" \
  --arg nb_pg      "$NB_PEER_GROUP_ID" \
  --arg nb_deny    "$NB_DENY_GROUP_ID" \
  --arg nb_ns      "$NB_NS_ID" \
  '{vpc:$vpc,igw:$igw,ep_subnet:$ep_subnet,peer_subnet:$pr_subnet,peer_rtb:$pr_rtb,
    ep_sg:$ep_sg,peer_sg:$peer_sg,service_network_arn:$sn_arn,endpoint:$endpoint,
    ram_share_arn:$share_arn,peer_instance:$instance,
    nb_peer:$nb_peer,nb_route:$nb_route,nb_policy:$nb_policy,
    nb_group:$nb_group,nb_peer_group:$nb_pg,nb_deny_group:$nb_deny,nb_ns:$nb_ns}' \
  > "$EVIDENCE/resources.json"

echo
echo "Access cell ready. Evidence: $EVIDENCE/"
echo "Teardown order (access-down.sh):"
echo "  1 NetBird ns/route/policy/groups/peer"
echo "  2 RAM share"
echo "  3 VPC endpoint"
echo "  4 service network"
echo "  5 EC2 instance"
echo "  6 IAM role/profile"
echo "  7 security groups"
echo "  8 subnets / route table"
echo "  9 IGW"
echo " 10 VPC"
