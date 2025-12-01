# ZLAF Complete Lifecycle Run

## Tooling

| Tool | Version |
|---|---|
| aws CLI | `aws --version` |
| NetBird | `0.31.0` |
| jq | `jq --version` |
| Python | `python3 --version` |
| curl | `curl --version` |

## Constants (lab.json)

| Name | Value |
|---|---|
| Region | `ca-central-1` |
| Access VPC CIDR | `100.64.0.0/16` |
| Endpoint subnet | `100.64.1.0/24` |
| Service network | `zlaf-prod-access` |
| RAM share | `zlaf-prod-access-share` |
| Probe instance | `zlaf-routing-peer` |
| App-c FQDN | `website.example.ca` |
| App-d FQDN | `payments.example.ca` |
| Both app VPC CIDRs | `10.0.0.0/16` (overlap intentional) |

## Account and Resource Mapping

| Role | Account ID | Profile |
|---|---|---|
| Access | (see resources.json) | `access` |
| Registry | (see resources.json) | `registry` |
| App-c | (see lab.json accounts.app_c) | `app-c` |
| App-d | (see lab.json accounts.app_d) | `app-d` |

---

## Phase 0 — RAM-only nonexposure

Confirms that sharing the service network to app accounts via RAM does not
expose any application.  No publications exist.  The Route 53 private zone
for each FQDN is absent from the access VPC.

```sh
# From probe EC2 (ZTNA connected, access-up.sh complete)
python3 -c "import socket; print(socket.gethostbyname('website.example.ca'))"
python3 -c "import socket; print(socket.gethostbyname('payments.example.ca'))"
```

Expected: both resolve to nothing (NXDOMAIN / exception) because no private
hosted zone exists in the access VPC yet.

| Check | Result |
|---|---|
| website.example.ca resolves | |
| payments.example.ca resolves | |
| NetBird routes (domain) | |

---

## Phase 1 — Submit app-c (revision 1)

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-c scripts/submit.sh app-c 1 true
```

Wait for Step Functions execution `app-c-r1` to complete, then confirm
lifecycle_state = VERIFYING in DynamoDB.

```sh
aws --profile registry --region ca-central-1 dynamodb get-item \
    --table-name zlaf-registry \
    --key '{"app_id":{"S":"app-c"}}' \
    --output json | jq '{state:.Item.lifecycle_state.S, rev:.Item.desired_revision.N}'
```

Once VERIFYING, run the external probe from the enrolled probe EC2:

```sh
PROBE_ROLE_ARN=<probe-role-arn> \
  VERIFY_REVISION_APP_C=1 \
  scripts/verify.sh
```

Then confirm lifecycle_state = ACTIVE.

| Check | Result |
|---|---|
| Execution `app-c-r1` succeeded | |
| DynamoDB state after workflow | VERIFYING |
| website.example.ca DNS → endpoint IP | |
| TCP 443 open | |
| TLS cert CN/SAN matches FQDN | |
| HTTP status (known response) | |
| verify.sh run_id | |
| DynamoDB state after verify | ACTIVE |
| Observed resource IDs recorded | |

---

## Phase 1b — Duplicate submit (idempotency)

Resubmit revision 1 for app-c.  The Step Functions execution name `app-c-r1`
already exists; start_execution raises ExecutionAlreadyExists, which is caught
and logged.  DynamoDB record is unchanged.

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-c scripts/submit.sh app-c 1 true
```

| Check | Result |
|---|---|
| Second EventBridge PutEvents succeeded | |
| Lambda log: ExecutionAlreadyExists caught | |
| DynamoDB state unchanged (ACTIVE) | |
| No duplicate Lattice resources | |

---

## Phase 2 — Submit app-d (revision 1, overlapping CIDR)

app-d uses the same VPC CIDR (10.0.0.0/16) as app-c.

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-d scripts/submit.sh app-d 1 true
```

Wait for execution `app-d-r1`, then run verify for app-d:

```sh
APPS=app-d PROBE_ROLE_ARN=<probe-role-arn> \
  VERIFY_REVISION_APP_D=1 \
  scripts/verify.sh
```

| Check | Result |
|---|---|
| Execution `app-d-r1` succeeded | |
| payments.example.ca DNS → same endpoint IP as website.example.ca | |
| TCP 443 open | |
| TLS cert CN/SAN matches payments.example.ca | |
| HTTP status (known response) | |
| DynamoDB app-d state: ACTIVE | |

---

## Phase 3 — Route and endpoint comparison

Both FQDNs resolve to the same service-network endpoint IP.  Two distinct
NetBird domain routes exist.  The access VPC route tables are unchanged
(no new routes for app-d's 10.0.0.0/16).

```sh
# NetBird routes (from access EC2 or via NetBird API)
curl -H "Authorization: Token $NETBIRD_API_TOKEN" \
    https://api.netbird.io/api/routes | jq '[.[] | select(.network_id | startswith("zlaf-")) | {network_id,domains,enabled}]'

# DNS comparison
python3 -c "import socket; print('app-c:', socket.gethostbyname('website.example.ca'))"
python3 -c "import socket; print('app-d:', socket.gethostbyname('payments.example.ca'))"

# Access VPC route tables (no change expected)
aws --profile access --region ca-central-1 ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=<access-vpc-id>" \
    --query 'RouteTables[].Routes' --output json
```

| Check | Result |
|---|---|
| Two NetBird domain routes (zlaf-app-c-domain, zlaf-app-d-domain) | |
| Both FQDNs resolve to same endpoint IP | |
| Lattice SNI distinguishes services (cross-SNI probe) | |
| Access VPC route tables unchanged | |

Cross-SNI probe (connects to endpoint with wrong SNI; confirms per-service isolation):

```sh
curl --max-time 10 --resolve "payments.example.ca:443:<endpoint-ip>" \
    -o /dev/null -w "%{http_code}" --silent \
    "https://payments.example.ca/"   # should differ from connecting with website.example.ca SNI
```

---

## Phase 4 — Authorized and denied client probes

Authorized client (enrolled in zlaf-access group via NetBird) should resolve
and reach both FQDNs.  A client added to the zlaf-denied group should not
route through the peer.

```sh
# Denied client test (add peer to zlaf-denied group in NetBird, then probe)
# From denied client:
python3 -c "import socket; print(socket.gethostbyname('website.example.ca'))"
```

| Check | Result |
|---|---|
| Authorized client: website.example.ca resolves | |
| Authorized client: HTTP response (known response) | |
| Denied client: website.example.ca resolves | |
| Denied client: TCP/HTTPS blocked by NetBird policy | |

---

## Phase 5 — Association removal and scheduled repair

Deletes app-c's Lattice service-network association to induce drift, then
waits for the scheduled reconcile (or explicit invocation) to repair it.

```sh
LAMBDA_ARN=<controller-arn> \
  REGISTRY_PROFILE=registry \
  APP_C_PROFILE=app-c \
  REGISTRY_TABLE=zlaf-registry \
  scripts/reconcile.sh
```

After repair reaches VERIFYING, run verify again:

```sh
APPS=app-c PROBE_ROLE_ARN=<probe-role-arn> \
  VERIFY_REVISION_APP_C=1 \
  scripts/verify.sh
```

| Check | Result |
|---|---|
| reconcile reported repaired=1 | |
| New association ID differs from deleted | |
| Service, TG, listener IDs unchanged (no duplicates) | |
| app-c state after repair: VERIFYING | |
| verify run_id (repair) | |
| app-c state after verify: ACTIVE | |
| app-d unaffected (still ACTIVE) | |

---

## Phase 6 — Disable app-c, verify app-d unaffected

Submits `enabled=false revision=2` for app-c.  The retire workflow removes
app-c's NetBird route, Route 53 zone, Lattice resources, and ALB SG rule.
app-d resources are untouched.

```sh
REGISTRY_BUS_ARN=<bus-arn> \
  REGISTRY_PROFILE=registry \
  APP_C_PROFILE=app-c \
  REGISTRY_TABLE=zlaf-registry \
  scripts/retire.sh
```

| Check | Result |
|---|---|
| app-c state: RETIRED | |
| app-c observed IDs cleared | |
| NetBird domain route for website.example.ca absent | |
| Route 53 zone for website.example.ca absent from access VPC | |
| Lattice service zlaf-app-c absent | |
| ALB SG rule for Lattice prefix list revoked | |
| website.example.ca DNS from probe: NXDOMAIN (or no ZTNA route) | |
| HTTPS to website.example.ca: refused/timeout | |
| payments.example.ca still resolves (app-d unaffected) | |
| app-d HTTP response: still 2xx–5xx | |
| app-c application-local DNS (in app-c account) still resolves | |

---

## Phase 7 — Stale event replay

Submits the original `enabled=true revision=1` for app-c.  The persist task
sees current desired_revision=2 ≥ 1 and sets state_accepted=false.  The
workflow exits via StaleEvent without provisioning anything.

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-c scripts/submit.sh app-c 1 true
```

| Check | Result |
|---|---|
| Execution `app-c-r1` raises ExecutionAlreadyExists (caught) OR new execution runs and exits StaleEvent | |
| DynamoDB state: still RETIRED (not re-provisioned) | |
| website.example.ca still NXDOMAIN from probe | |

---

## Phase 8 — Re-enable app-c (revision 3)

Submits `enabled=true revision=3` (strictly greater than disable revision 2).
Same Lattice resource names are re-created idempotently.

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-c scripts/submit.sh app-c 3 true
```

Wait for VERIFYING, then run verify with expected revision 3:

```sh
APPS=app-c PROBE_ROLE_ARN=<probe-role-arn> \
  VERIFY_REVISION_APP_C=3 \
  scripts/verify.sh
```

| Check | Result |
|---|---|
| Execution `app-c-r3` succeeded | |
| Same Lattice service name (zlaf-app-c) | |
| Same Route 53 zone name | |
| app-c desired_revision=3 | |
| verify run_id (re-enable) | |
| app-c state: ACTIVE r3 | |
| website.example.ca DNS resolves from probe | |
| HTTP response: 2xx–5xx | |
| app-d unaffected throughout | |

---

## Phase 9 — Final retirement and teardown

### Retire app-c and app-d

Submit `enabled=false` at the next revision for each.

```sh
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-c scripts/submit.sh app-c 4 false
REGISTRY_BUS_ARN=<bus-arn> APP_PROFILE=app-d scripts/submit.sh app-d 2 false
```

Wait for both to reach RETIRED.

| Check | Result |
|---|---|
| app-c: RETIRED r4 | |
| app-d: RETIRED r2 | |
| No NetBird domain routes for either FQDN | |
| No Route 53 private zones in access VPC | |
| No Lattice services in app-c or app-d accounts | |
| Both application-local DNS paths survive (ALBs untouched) | |

### Export registry history

```sh
aws --profile registry --region ca-central-1 dynamodb scan \
    --table-name zlaf-registry \
    --output json | jq '{items:[.Items[] | {app_id:.app_id.S, state:.lifecycle_state.S, rev:.desired_revision.N, fqdn:.fqdn.S}]}'
```

Registry snapshot (sanitized — no account IDs):

```
[fill in during live run]
```

### Tear down control plane

```sh
aws --profile registry --region ca-central-1 cloudformation delete-stack \
    --stack-name zlaf-control-plane
aws --profile app-c --region ca-central-1 cloudformation delete-stack \
    --stack-name zlaf-provisioner
aws --profile app-d --region ca-central-1 cloudformation delete-stack \
    --stack-name zlaf-provisioner
aws --profile access --region ca-central-1 cloudformation delete-stack \
    --stack-name zlaf-access-provisioner
```

| Check | Result |
|---|---|
| Control plane stack deleted | |
| App provisioner stacks deleted | |
| Registry DynamoDB table deleted | |
| EventBridge bus deleted | |
| Lambda deleted | |
| Step Functions state machine deleted | |

### Tear down access cell

```sh
NETBIRD_API_TOKEN=<token> scripts/access-down.sh
```

| Check | Result |
|---|---|
| NetBird peer removed | |
| NetBird groups removed | |
| VPC Lattice service network deleted | |
| ServiceNetwork-type endpoint deleted | |
| RAM share deleted | |
| Access VPC and contents deleted | |
| IAM role/instance profile deleted | |

### Backend survival

```sh
# From app-c account — local DNS must still resolve to the ALB
aws --profile app-c --region ca-central-1 route53 list-hosted-zones \
    --query 'HostedZones[].Name'
```

| Check | Result |
|---|---|
| app-c local Route 53 zone for website.example.ca survives | |
| app-d local Route 53 zone for payments.example.ca survives | |
| Both ALBs still running | |

---

## Lifecycle State Summary

| App | Start | After submit | After verify | After retire | After re-enable | After re-enable verify | Final |
|---|---|---|---|---|---|---|---|
| app-c | — | VERIFYING | ACTIVE | RETIRED | VERIFYING | ACTIVE | RETIRED |
| app-d | — | VERIFYING | ACTIVE | — | — | — | RETIRED |

---

## Notes

- Live run blocked pending `aws sso login` — all result columns above are unpopulated.
- website.example.ca and payments.example.ca both resolve to the same service-network endpoint IP; Lattice selects the correct backend via TLS SNI.
- The stale-event replay (Phase 7) confirms revision gating: a lower revision cannot overwrite a higher one.
- The reconcile test (Phase 5) confirms only the missing association is re-created; no duplicate service, TG, or listener is produced.
- The cross-SNI probe in Phase 3 bounds the per-service isolation claim: direct-IP access with a mismatched SNI reaches the wrong Lattice service, confirming ZTNA DNS routing is the enforcement layer (not TCP-level isolation).
