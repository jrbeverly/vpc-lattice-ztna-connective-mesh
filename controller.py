#!/usr/bin/env python3
"""
ZLAF registry controller — Lambda handler.

Entry points:
  SQS trigger (aws:sqs)
    Parses EventBridge event envelope, starts one SF execution per record.
    Execution name: {app_id}-r{revision}  (idempotent by name)

  SF task invocation
    event = {"task": "...", "ctx": {...}}
    Returns {"ctx": {...updated...}}

  EventBridge scheduled event (source == "aws.events")
    Scans DynamoDB, starts repair executions for drifted ACTIVE/VERIFYING records.

  Explicit reconcile
    event = {"task": "reconcile"}
    Same as scheduled event; useful for bounded testing.

Tasks (provision workflow order):
  validate           check source-account/app_id mapping; verify FQDN→ALB
  persist            write desired state to DynamoDB (revision-gated)
  ensure_publication create/reuse Lattice TG, service, listener, association
  check_association  poll association status; increment tries counter
  ensure_dns         create/reuse R53 private zone + apex record (access acct)
  ensure_ztna        create/reuse NetBird exact-FQDN domain route
  mark_verifying     persist all observed IDs; set lifecycle_state=VERIFYING
  record_rejection   persist REJECTED state with cause

Tasks (retirement workflow order):
  load_record        read DynamoDB observed IDs into ctx
  retire_ztna        delete NetBird domain route; record propagation timestamp
  retire_dns         delete R53 private zone and apex record
  retire_publication disassociate + delete Lattice resources; revoke ALB SG rule
  mark_retired       set lifecycle_state=RETIRED; clear observed IDs

Reconcile task:
  reconcile          scan all ACTIVE/VERIFYING records; start repair executions
                     for any whose observed association is missing or non-ACTIVE

Environment variables (set by control-plane.yaml):
  TABLE_NAME, STATE_MACHINE_ARN, NB_SECRET_ARN, NB_MGMT_URL,
  LAB_REGION, ACCESS_VPC_ID, ENDPOINT_ID, EP_SUBNET_ID, NB_PEER_ID,
  SERVICE_NETWORK_ARN, APP_C_ACCOUNT, APP_D_ACCOUNT,
  ACCESS_ACCOUNT, PROVISIONER_ROLE
"""
import json
import os
import time
import urllib.request
import urllib.error

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

REGION    = os.environ.get("LAB_REGION", "ca-central-1")
TABLE     = os.environ["TABLE_NAME"]
SF_ARN    = os.environ.get("STATE_MACHINE_ARN", "")
NB_ARN    = os.environ["NB_SECRET_ARN"]
NB_URL    = os.environ.get("NB_MGMT_URL", "https://api.netbird.io")
SN_ARN    = os.environ["SERVICE_NETWORK_ARN"]
ACCESS_VPC = os.environ["ACCESS_VPC_ID"]
EP_ID     = os.environ["ENDPOINT_ID"]
EP_SUB    = os.environ["EP_SUBNET_ID"]
NB_PEER   = os.environ["NB_PEER_ID"]
PROV_ROLE = os.environ.get("PROVISIONER_ROLE", "zlaf-fabric-provisioner")

APP_ACCOUNT_MAP = {
    os.environ["APP_C_ACCOUNT"]: "app-c",
    os.environ["APP_D_ACCOUNT"]: "app-d",
}
ACCESS_ACCOUNT = os.environ["ACCESS_ACCOUNT"]

_dynamo   = boto3.resource("dynamodb", region_name=REGION)
_registry = _dynamo.Table(TABLE)
_sf       = boto3.client("stepfunctions", region_name=REGION)
_sm       = boto3.client("secretsmanager", region_name=REGION)

_nb_token = None


def _nb_token_value():
    global _nb_token
    if _nb_token is None:
        _nb_token = json.loads(
            _sm.get_secret_value(SecretId=NB_ARN)["SecretString"]
        )["token"]
    return _nb_token


def nb(method, path, body=None):
    url  = f"{NB_URL}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Token {_nb_token_value()}")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"NetBird {method} {path}: {e.code} {e.read().decode()}")


def assume_session(account_id):
    """Assume zlaf-fabric-provisioner in the given account."""
    sts   = boto3.client("sts", region_name=REGION)
    arn   = f"arn:aws:iam::{account_id}:role/{PROV_ROLE}"
    creds = sts.assume_role(RoleArn=arn, RoleSessionName="zlaf-controller")["Credentials"]
    return boto3.Session(
        aws_access_key_id     = creds["AccessKeyId"],
        aws_secret_access_key = creds["SecretAccessKey"],
        aws_session_token     = creds["SessionToken"],
        region_name           = REGION,
    )


# ── Entry point ───────────────────────────────────────────────────────────────

def handler(event, context):
    records = event.get("Records", [])
    if records and records[0].get("eventSource") == "aws:sqs":
        failures = []
        for rec in records:
            eb  = json.loads(rec["body"])
            det = eb.get("detail", {})
            det["_source_aws_account"] = eb.get("account", "")
            try:
                _start_execution(det)
            except Exception as e:
                print(f"ERROR launching execution for {rec['messageId']}: {e}")
                failures.append({"itemIdentifier": rec["messageId"]})
        return {"batchItemFailures": failures}

    # EventBridge scheduled rule or explicit reconcile invocation
    if event.get("source") == "aws.events" or event.get("task") == "reconcile":
        return task_reconcile({}, event)

    task = event.get("task")
    ctx  = event.get("ctx", {})
    dispatch = {
        "validate":            task_validate,
        "persist":             task_persist,
        "ensure_publication":  task_ensure_publication,
        "check_association":   task_check_association,
        "ensure_dns":          task_ensure_dns,
        "ensure_ztna":         task_ensure_ztna,
        "mark_verifying":      task_mark_verifying,
        "record_rejection":    task_record_rejection,
        "load_record":         task_load_record,
        "retire_ztna":         task_retire_ztna,
        "retire_dns":          task_retire_dns,
        "retire_publication":  task_retire_publication,
        "mark_retired":        task_mark_retired,
    }
    if task not in dispatch:
        raise ValueError(f"Unknown task: {task!r}")
    return {"ctx": dispatch[task](ctx, event)}


def _start_execution(detail):
    app_id   = detail["app_id"]
    revision = int(detail.get("revision", 1))
    name     = f"{app_id}-r{revision}"
    try:
        _sf.start_execution(
            stateMachineArn = SF_ARN,
            name            = name,
            input           = json.dumps({"ctx": {
                "app_id":             app_id,
                "fqdn":               detail["fqdn"],
                "account_id":         detail["account_id"],
                "source_aws_account": detail.get("_source_aws_account",
                                                 detail["account_id"]),
                "region":             detail.get("region", REGION),
                "port":               int(detail.get("port", 443)),
                "environment":        detail.get("environment", "prod"),
                "enabled":            bool(detail.get("enabled", True)),
                "revision":           revision,
                "tries":              0,
            }}),
        )
        print(f"Started execution {name}")
    except _sf.exceptions.ExecutionAlreadyExists:
        print(f"Execution {name} already exists — idempotent skip")


# ── Task: validate ────────────────────────────────────────────────────────────

def task_validate(ctx, _event):
    app_id     = ctx["app_id"]
    account_id = ctx["account_id"]
    src_acct   = ctx.get("source_aws_account", account_id)
    fqdn       = ctx["fqdn"]
    port       = int(ctx.get("port", 443))

    # Source account must match the fixed enrollment mapping
    if src_acct not in APP_ACCOUNT_MAP:
        raise ValueError(f"Source account {src_acct} not in allowed enrollment mapping")
    if APP_ACCOUNT_MAP[src_acct] != app_id:
        raise ValueError(
            f"app_id {app_id!r} does not match source account {src_acct} "
            f"(expected {APP_ACCOUNT_MAP[src_acct]!r})"
        )
    if account_id != src_acct:
        raise ValueError(
            f"detail.account_id {account_id} != event source account {src_acct}"
        )

    sess = assume_session(account_id)
    elb  = sess.client("elbv2")
    r53a = sess.client("route53")

    # Find a private hosted zone with an alias record for FQDN pointing at an ALB
    alb_dns_name = None
    for zone in r53a.list_hosted_zones()["HostedZones"]:
        if not zone["Config"]["PrivateZone"]:
            continue
        zone_name = zone["Name"].rstrip(".")
        if fqdn != zone_name and not fqdn.endswith("." + zone_name):
            continue
        zone_id = zone["Id"].split("/")[-1]
        rrsets  = r53a.list_resource_record_sets(
            HostedZoneId=zone_id, StartRecordName=fqdn, MaxItems="5"
        )["ResourceRecordSets"]
        for rr in rrsets:
            if rr["Name"].rstrip(".") != fqdn:
                continue
            alias = rr.get("AliasTarget", {}).get("DNSName", "").rstrip(".")
            if ".elb." in alias and "amazonaws.com" in alias:
                alb_dns_name = alias
                break
        if alb_dns_name:
            break

    if not alb_dns_name:
        raise ValueError(
            f"No private DNS alias to an ALB found for {fqdn} in account {account_id}"
        )

    albs = elb.describe_load_balancers()["LoadBalancers"]
    alb  = next(
        (a for a in albs
         if a["Scheme"] == "internal"
         and (alb_dns_name.startswith(a["DNSName"])
              or a["DNSName"].startswith(alb_dns_name))),
        None,
    )
    if alb is None:
        raise ValueError(
            f"Internal ALB matching DNS {alb_dns_name} not found in {account_id}"
        )

    listeners = elb.describe_listeners(
        LoadBalancerArn=alb["LoadBalancerArn"]
    )["Listeners"]
    if not any(int(l["Port"]) == port for l in listeners):
        raise ValueError(
            f"ALB {alb['LoadBalancerArn']} has no listener on port {port}"
        )

    print(f"  validate OK: {fqdn} → {alb['LoadBalancerArn']} vpc={alb['VpcId']}")
    return {
        **ctx,
        "backend_arn": alb["LoadBalancerArn"],
        "alb_vpc_id":  alb["VpcId"],
        "alb_sg":      alb["SecurityGroups"][0],
    }


# ── Task: persist ─────────────────────────────────────────────────────────────

def task_persist(ctx, _event):
    app_id   = ctx["app_id"]
    revision = int(ctx["revision"])
    enabled  = ctx["enabled"]

    # Repair executions share the existing revision; skip the write and signal accepted.
    if ctx.get("repair"):
        print(f"  persist: repair mode, skipping state write for {app_id}")
        return {**ctx, "state_accepted": True}

    lifecycle_state = "PROVISIONING" if enabled else "DECOMMISSIONING"
    item = {
        "app_id":           app_id,
        "fqdn":             ctx["fqdn"],
        "account_id":       ctx["account_id"],
        "region":           ctx["region"],
        "port":             ctx["port"],
        "environment":      ctx["environment"],
        "desired_enabled":  enabled,
        "desired_revision": revision,
        "lifecycle_state":  lifecycle_state,
        "updated_at":       int(time.time()),
    }

    try:
        _registry.put_item(
            Item                = item,
            ConditionExpression = (
                Attr("app_id").not_exists() |
                Attr("desired_revision").lt(revision)
            ),
        )
        print(f"  persisted desired state: {app_id} r{revision} enabled={enabled}")
        return {**ctx, "state_accepted": True}
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        existing = _registry.get_item(Key={"app_id": app_id}).get("Item", {})
        ex_rev   = int(existing.get("desired_revision", 0))
        print(f"  persist skipped: existing revision {ex_rev} >= {revision}")
        # Return current authoritative enabled so PersistRouter uses the DB value.
        return {
            **ctx,
            "state_accepted": False,
            "enabled":        existing.get("desired_enabled", enabled),
        }


# ── Task: ensure_publication ──────────────────────────────────────────────────

def task_ensure_publication(ctx, _event):
    app_id     = ctx["app_id"]
    fqdn       = ctx["fqdn"]
    account_id = ctx["account_id"]
    alb_arn    = ctx["backend_arn"]
    alb_vpc    = ctx["alb_vpc_id"]
    alb_sg     = ctx["alb_sg"]

    sess = assume_session(account_id)
    lat  = sess.client("vpc-lattice")
    ec2a = sess.client("ec2")

    # Permit Lattice prefix list on the ALB SG
    pl_resp = ec2a.describe_managed_prefix_lists(
        Filters=[
            {"Name": "prefix-list-name",
             "Values": [f"com.amazonaws.{REGION}.vpc-lattice"]},
            {"Name": "owner-id", "Values": ["AWS"]},
        ]
    )["PrefixLists"]
    if not pl_resp:
        raise RuntimeError(f"VPC Lattice prefix list not found in {REGION}")
    pl_id = pl_resp[0]["PrefixListId"]
    try:
        ec2a.authorize_security_group_ingress(
            GroupId=alb_sg,
            IpPermissions=[{
                "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                "PrefixListIds": [{"PrefixListId": pl_id,
                                   "Description": "zlaf-lattice"}],
            }],
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidPermission.Duplicate":
            raise

    # Lattice target group — idempotent by name
    tg_name = f"zlaf-{app_id}-tg"
    tg_id = tg_arn = None
    for item in lat.list_target_groups()["items"]:
        if item["name"] == tg_name:
            tg_id  = item["id"]
            tg_arn = item["arn"]
            break
    if tg_id is None:
        tg    = lat.create_target_group(
            name   = tg_name,
            type   = "ALB",
            config = {"port": 443, "protocol": "TCP", "vpcIdentifier": alb_vpc},
        )
        tg_id  = tg["id"]
        tg_arn = tg["arn"]
    try:
        lat.register_targets(
            targetGroupIdentifier = tg_id,
            targets               = [{"id": alb_arn, "port": 443}],
        )
    except ClientError as e:
        if "already registered" not in str(e).lower():
            raise

    # Lattice service — idempotent by name
    svc_name = f"zlaf-{app_id}"
    svc_id = svc_arn = svc_dns = None
    for item in lat.list_services()["items"]:
        if item["name"] == svc_name:
            svc_id  = item["id"]
            svc_arn = item["arn"]
            svc     = lat.get_service(serviceIdentifier=svc_id)
            svc_dns = svc.get("dnsEntry", {}).get("domainName", "")
            break
    if svc_id is None:
        svc    = lat.create_service(
            name             = svc_name,
            authType         = "NONE",
            customDomainName = fqdn,
        )
        svc_id  = svc["id"]
        svc_arn = svc["arn"]
        svc_dns = svc.get("dnsEntry", {}).get("domainName", "")
        for _ in range(24):
            s = lat.get_service(serviceIdentifier=svc_id)
            if s.get("status") == "ACTIVE":
                break
            if "FAIL" in s.get("status", ""):
                raise RuntimeError(f"Lattice service entered {s['status']}")
            time.sleep(5)

    # Listener — idempotent by name
    lst_name = "tls-passthrough-443"
    lst_id = lst_arn = None
    for item in lat.list_listeners(serviceIdentifier=svc_id)["items"]:
        if item["name"] == lst_name:
            lst_id  = item["id"]
            lst_arn = item["arn"]
            break
    if lst_id is None:
        lst    = lat.create_listener(
            serviceIdentifier = svc_id,
            name              = lst_name,
            protocol          = "TLS_PASSTHROUGH",
            port              = 443,
            defaultAction     = {
                "forward": {
                    "targetGroups": [{"targetGroupIdentifier": tg_id, "weight": 100}]
                }
            },
        )
        lst_id  = lst["id"]
        lst_arn = lst["arn"]

    # Service-network association — idempotent
    assoc_id = None
    for item in lat.list_service_network_service_associations(
        serviceNetworkIdentifier=SN_ARN
    )["items"]:
        if item.get("serviceArn") == svc_arn:
            assoc_id = item["id"]
            break
    if assoc_id is None:
        assoc    = lat.create_service_network_service_association(
            serviceIdentifier        = svc_arn,
            serviceNetworkIdentifier = SN_ARN,
        )
        assoc_id = assoc["id"]

    print(f"  publication: tg={tg_id} svc={svc_id} lst={lst_id} assoc={assoc_id}")
    return {
        **ctx,
        "tg_id":            tg_id,   "tg_arn":  tg_arn,
        "svc_id":           svc_id,  "svc_arn": svc_arn,  "svc_dns": svc_dns,
        "lst_id":           lst_id,  "lst_arn": lst_arn,
        "assoc_id":         assoc_id,
        "lattice_pl":       pl_id,
        "association_ready": False,
    }


# ── Task: check_association ───────────────────────────────────────────────────

def task_check_association(ctx, _event):
    account_id = ctx["account_id"]
    assoc_id   = ctx["assoc_id"]
    tries      = int(ctx.get("tries", 0)) + 1

    sess  = assume_session(account_id)
    lat   = sess.client("vpc-lattice")
    assoc = lat.get_service_network_service_association(
        serviceNetworkServiceAssociationIdentifier=assoc_id
    )
    status = assoc.get("status", "")
    print(f"  association {assoc_id}: {status} (try {tries})")
    if "FAIL" in status:
        raise RuntimeError(f"Lattice association entered {status}")

    return {**ctx, "tries": tries, "association_ready": status == "ACTIVE"}


# ── Task: ensure_dns ──────────────────────────────────────────────────────────

def task_ensure_dns(ctx, _event):
    fqdn   = ctx["fqdn"]
    app_id = ctx["app_id"]

    # All Route53 and EC2 operations are in the access account
    acc_sess = assume_session(ACCESS_ACCOUNT)
    ec2a     = acc_sess.client("ec2")
    r53      = acc_sess.client("route53")

    ep_raw  = ec2a.describe_vpc_endpoints(VpcEndpointIds=[EP_ID])["VpcEndpoints"][0]
    entries = ep_raw.get("DnsEntries", [])
    alias_mode = "a_record"
    ep_dns = ep_hz = None
    if entries and entries[0].get("HostedZoneId"):
        ep_dns     = entries[0]["DnsName"]
        ep_hz      = entries[0]["HostedZoneId"]
        alias_mode = "alias"
    else:
        enis = ec2a.describe_network_interfaces(
            Filters=[{"Name": "subnet-id", "Values": [EP_SUB]}]
        )["NetworkInterfaces"]
        if not enis:
            raise RuntimeError("Endpoint has no DnsEntries and no ENI in endpoint subnet")
        ep_dns = enis[0]["PrivateIpAddress"]

    # R53 private zone — idempotent (same name, same VPC)
    zone_id = None
    for z in r53.list_hosted_zones_by_name(DNSName=f"{fqdn}.", MaxItems="5")[
        "HostedZones"
    ]:
        if z["Name"].rstrip(".") == fqdn and z["Config"]["PrivateZone"]:
            zone_id = z["Id"].split("/")[-1]
            break
    if zone_id is None:
        caller_ref = f"zlaf-pub-{app_id}-{fqdn.replace('.', '-')}"
        zone    = r53.create_hosted_zone(
            Name             = f"{fqdn}.",
            HostedZoneConfig = {"Comment": "zlaf split-view", "PrivateZone": True},
            CallerReference  = caller_ref,
            VPC              = {"VPCRegion": REGION, "VPCId": ACCESS_VPC},
        )
        zone_id = zone["HostedZone"]["Id"].split("/")[-1]

    # Apex record — delete-then-create for idempotency
    if alias_mode == "alias":
        rrset = {
            "Name": f"{fqdn}.", "Type": "A",
            "AliasTarget": {
                "HostedZoneId":        ep_hz,
                "DNSName":             f"{ep_dns}.",
                "EvaluateTargetHealth": False,
            },
        }
    else:
        rrset = {
            "Name": f"{fqdn}.", "Type": "A", "TTL": 60,
            "ResourceRecords": [{"Value": ep_dns}],
        }

    existing_rrs = r53.list_resource_record_sets(
        HostedZoneId=zone_id, StartRecordName=fqdn, MaxItems="1"
    )["ResourceRecordSets"]
    changes = []
    if existing_rrs and existing_rrs[0]["Name"].rstrip(".") == fqdn:
        changes.append({"Action": "DELETE", "ResourceRecordSet": existing_rrs[0]})
    changes.append({"Action": "CREATE", "ResourceRecordSet": rrset})
    r53.change_resource_record_sets(
        HostedZoneId=zone_id,
        ChangeBatch={"Changes": changes},
    )

    print(f"  dns: zone={zone_id} {alias_mode} {fqdn} → {ep_dns}")
    return {
        **ctx,
        "zone_id":    zone_id,
        "ep_dns":     ep_dns,
        "ep_hz":      ep_hz,
        "alias_mode": alias_mode,
    }


# ── Task: ensure_ztna ─────────────────────────────────────────────────────────

def task_ensure_ztna(ctx, _event):
    app_id = ctx["app_id"]
    fqdn   = ctx["fqdn"]

    network_id = f"zlaf-{app_id}-domain"
    groups     = nb("GET", "/api/groups")
    access_gid = next((g["id"] for g in groups if g["name"] == "zlaf-access"), None)
    if access_gid is None:
        raise RuntimeError("NetBird group 'zlaf-access' not found")

    routes   = nb("GET", "/api/routes")
    existing = next((r for r in routes if r.get("network_id") == network_id), None)
    if existing:
        nb_route_id = existing["id"]
        print(f"  ztna: reusing route {nb_route_id}")
    else:
        route = nb("POST", "/api/routes", {
            "description": f"zlaf {fqdn} tcp/443",
            "network_id":  network_id,
            "domains":     [fqdn],
            "peer":        NB_PEER,
            "enabled":     True,
            "masquerade":  False,
            "metric":      9998,
            "groups":      [access_gid],
        })
        nb_route_id = route["id"]
        print(f"  ztna: created route {nb_route_id}")

    return {**ctx, "nb_route_id": nb_route_id}


# ── Task: mark_verifying ──────────────────────────────────────────────────────

def task_mark_verifying(ctx, _event):
    app_id = ctx["app_id"]
    _registry.update_item(
        Key              = {"app_id": app_id},
        UpdateExpression = (
            "SET lifecycle_state     = :s, "
            "publication_model      = :m, "
            "observed_tg_id         = :tg, "
            "observed_svc_id        = :svc, "
            "observed_lst_id        = :lst, "
            "observed_assoc_id      = :assoc, "
            "observed_zone_id       = :zone, "
            "observed_nb_route_id   = :nb, "
            "observed_backend_arn   = :bk, "
            "updated_at             = :ts"
        ),
        ExpressionAttributeValues={
            ":s":     "VERIFYING",
            ":m":     "lattice-service",
            ":tg":    ctx.get("tg_id", ""),
            ":svc":   ctx.get("svc_id", ""),
            ":lst":   ctx.get("lst_id", ""),
            ":assoc": ctx.get("assoc_id", ""),
            ":zone":  ctx.get("zone_id", ""),
            ":nb":    ctx.get("nb_route_id", ""),
            ":bk":    ctx.get("backend_arn", ""),
            ":ts":    int(time.time()),
        },
    )
    print(f"  marked {app_id} VERIFYING")
    return ctx


# ── Task: record_rejection ────────────────────────────────────────────────────

def task_record_rejection(ctx, event):
    app_id = ctx.get("app_id", "unknown")
    cause  = str(event.get("error", {}).get("Cause", ""))
    _registry.update_item(
        Key              = {"app_id": app_id},
        UpdateExpression = (
            "SET lifecycle_state  = :s, "
            "rejection_cause     = :c, "
            "fqdn                = :fqdn, "
            "account_id          = :aid, "
            "updated_at          = :ts"
        ),
        ExpressionAttributeValues={
            ":s":    "REJECTED",
            ":c":    cause[:1000],
            ":fqdn": ctx.get("fqdn", ""),
            ":aid":  ctx.get("account_id", ""),
            ":ts":   int(time.time()),
        },
    )
    print(f"  recorded rejection for {app_id}: {cause[:200]}")
    return ctx


# ── Task: load_record ─────────────────────────────────────────────────────────

def task_load_record(ctx, _event):
    """Read current observed IDs from DynamoDB into ctx for the retirement path."""
    app_id = ctx["app_id"]
    item   = _registry.get_item(Key={"app_id": app_id}).get("Item", {})
    if not item:
        print(f"  load_record: no existing record for {app_id}")
        return {**ctx, "has_record": False}
    print(f"  load_record: found record for {app_id} state={item.get('lifecycle_state')}")
    return {
        **ctx,
        "has_record":   True,
        "tg_id":        item.get("observed_tg_id", ""),
        "svc_id":       item.get("observed_svc_id", ""),
        "lst_id":       item.get("observed_lst_id", ""),
        "assoc_id":     item.get("observed_assoc_id", ""),
        "zone_id":      item.get("observed_zone_id", ""),
        "nb_route_id":  item.get("observed_nb_route_id", ""),
        "backend_arn":  item.get("observed_backend_arn", ""),
    }


# ── Task: retire_ztna ─────────────────────────────────────────────────────────

def task_retire_ztna(ctx, _event):
    """Delete the NetBird domain route. DNS/policy propagation happens in the
    WaitPropagation Step Functions Wait state that follows this task."""
    nb_route_id = ctx.get("nb_route_id", "")
    if nb_route_id:
        routes = nb("GET", "/api/routes")
        if any(r["id"] == nb_route_id for r in routes):
            nb("DELETE", f"/api/routes/{nb_route_id}")
            print(f"  retire_ztna: deleted route {nb_route_id}")
        else:
            print(f"  retire_ztna: route {nb_route_id} already absent")
    else:
        print(f"  retire_ztna: no route id recorded, skipping")
    return {**ctx, "ztna_retired_at": int(time.time())}


# ── Task: retire_dns ──────────────────────────────────────────────────────────

def task_retire_dns(ctx, _event):
    """Delete the Route 53 split-view private zone for this application."""
    zone_id = ctx.get("zone_id", "")
    fqdn    = ctx["fqdn"]
    if not zone_id:
        print(f"  retire_dns: no zone_id recorded, skipping")
        return ctx

    acc_sess = assume_session(ACCESS_ACCOUNT)
    r53      = acc_sess.client("route53")

    # Delete non-SOA/NS records before the zone can be deleted
    try:
        rrsets = r53.list_resource_record_sets(HostedZoneId=zone_id)["ResourceRecordSets"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchHostedZone":
            print(f"  retire_dns: zone {zone_id} already absent")
            return {**ctx, "zone_id": ""}
        raise
    deletes = [
        {"Action": "DELETE", "ResourceRecordSet": rr}
        for rr in rrsets
        if rr["Type"] not in ("NS", "SOA")
    ]
    if deletes:
        r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={"Changes": deletes},
        )
    try:
        r53.delete_hosted_zone(Id=zone_id)
        print(f"  retire_dns: deleted zone {zone_id} ({fqdn})")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchHostedZone":
            raise
        print(f"  retire_dns: zone {zone_id} already absent")
    return {**ctx, "zone_id": ""}


# ── Task: retire_publication ──────────────────────────────────────────────────

def task_retire_publication(ctx, _event):
    """Disassociate the Lattice service, delete generated Lattice resources,
    and revoke the ALB security-group ingress rule added at publication time.
    Preserves the application ALB, its TLS certificate, and the application's
    own Route 53 DNS. The other application's Lattice resources are untouched."""
    account_id  = ctx["account_id"]
    assoc_id    = ctx.get("assoc_id", "")
    svc_id      = ctx.get("svc_id", "")
    lst_id      = ctx.get("lst_id", "")
    tg_id       = ctx.get("tg_id", "")
    backend_arn = ctx.get("backend_arn", "")

    sess = assume_session(account_id)
    lat  = sess.client("vpc-lattice")
    ec2a = sess.client("ec2")

    # 1. Delete service-network association first; wait for deletion to complete.
    if assoc_id:
        try:
            lat.delete_service_network_service_association(
                serviceNetworkServiceAssociationIdentifier=assoc_id
            )
            print(f"  retire_publication: deleting association {assoc_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] not in ("ResourceNotFoundException",):
                raise
            print(f"  retire_publication: association {assoc_id} already absent")
        # Poll until gone so subsequent service deletion is unblocked.
        for _ in range(30):
            try:
                status = lat.get_service_network_service_association(
                    serviceNetworkServiceAssociationIdentifier=assoc_id
                ).get("status", "")
                if status == "DELETE_FAILED":
                    raise RuntimeError(f"Association {assoc_id} entered DELETE_FAILED")
                time.sleep(5)
            except ClientError as e:
                if e.response["Error"]["Code"] == "ResourceNotFoundException":
                    break
                raise

    # 2. Delete listener.
    if lst_id and svc_id:
        try:
            lat.delete_listener(serviceIdentifier=svc_id, listenerIdentifier=lst_id)
            print(f"  retire_publication: deleted listener {lst_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceNotFoundException":
                raise

    # 3. Delete service; poll until gone so TG deletion is unblocked.
    if svc_id:
        try:
            lat.delete_service(serviceIdentifier=svc_id)
            print(f"  retire_publication: deleting service {svc_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceNotFoundException":
                raise
        for _ in range(30):
            try:
                s = lat.get_service(serviceIdentifier=svc_id)
                if "FAIL" in s.get("status", ""):
                    raise RuntimeError(f"Service {svc_id} entered {s['status']}")
                time.sleep(5)
            except ClientError as e:
                if e.response["Error"]["Code"] == "ResourceNotFoundException":
                    break
                raise

    # 4. Delete target group.
    if tg_id:
        try:
            lat.delete_target_group(targetGroupIdentifier=tg_id)
            print(f"  retire_publication: deleted TG {tg_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceNotFoundException":
                raise

    # 5. Revoke the Lattice prefix-list ingress rule from the application ALB SG.
    if backend_arn:
        try:
            albs = sess.client("elbv2").describe_load_balancers(
                LoadBalancerArns=[backend_arn]
            )["LoadBalancers"]
        except ClientError:
            albs = []
        if albs:
            alb_sg  = albs[0]["SecurityGroups"][0]
            pl_resp = ec2a.describe_managed_prefix_lists(
                Filters=[
                    {"Name": "prefix-list-name",
                     "Values": [f"com.amazonaws.{REGION}.vpc-lattice"]},
                    {"Name": "owner-id", "Values": ["AWS"]},
                ]
            )["PrefixLists"]
            if pl_resp:
                pl_id = pl_resp[0]["PrefixListId"]
                try:
                    ec2a.revoke_security_group_ingress(
                        GroupId=alb_sg,
                        IpPermissions=[{
                            "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                            "PrefixListIds": [{"PrefixListId": pl_id}],
                        }],
                    )
                    print(f"  retire_publication: revoked Lattice ingress from {alb_sg}")
                except ClientError as e:
                    if e.response["Error"]["Code"] != "InvalidPermission.NotFound":
                        raise
                    print(f"  retire_publication: ingress rule already absent on {alb_sg}")

    return {**ctx, "assoc_id": "", "svc_id": "", "lst_id": "", "tg_id": ""}


# ── Task: mark_retired ────────────────────────────────────────────────────────

def task_mark_retired(ctx, _event):
    app_id = ctx["app_id"]
    _registry.update_item(
        Key              = {"app_id": app_id},
        UpdateExpression = (
            "SET lifecycle_state     = :s, "
            "desired_enabled        = :f, "
            "observed_tg_id         = :empty, "
            "observed_svc_id        = :empty, "
            "observed_lst_id        = :empty, "
            "observed_assoc_id      = :empty, "
            "observed_zone_id       = :empty, "
            "observed_nb_route_id   = :empty, "
            "retired_at             = :ts, "
            "updated_at             = :ts"
        ),
        ExpressionAttributeValues={
            ":s":     "RETIRED",
            ":f":     False,
            ":empty": "",
            ":ts":    int(time.time()),
        },
    )
    print(f"  marked {app_id} RETIRED")
    return ctx


# ── Task: reconcile ───────────────────────────────────────────────────────────

def task_reconcile(_ctx, _event):
    """Scan all ACTIVE/VERIFYING records with desired_enabled=True and start
    a repair Step Functions execution for any whose observed Lattice association
    is missing or no longer ACTIVE. Skips records already in RECONCILING state."""
    items = _registry.scan()["Items"]
    repaired = 0

    for record in items:
        app_id = record["app_id"]
        if not record.get("desired_enabled", False):
            continue
        state = record.get("lifecycle_state", "")
        if state not in ("ACTIVE", "VERIFYING"):
            continue

        assoc_id   = record.get("observed_assoc_id", "")
        account_id = record.get("account_id", "")
        if not assoc_id or not account_id:
            print(f"  reconcile: {app_id} has no observed assoc/account, skipping")
            continue

        # Check whether the association still exists and is ACTIVE.
        drift = False
        try:
            sess  = assume_session(account_id)
            lat   = sess.client("vpc-lattice")
            assoc = lat.get_service_network_service_association(
                serviceNetworkServiceAssociationIdentifier=assoc_id
            )
            if assoc.get("status", "") != "ACTIVE":
                drift = True
                print(f"  reconcile: {app_id} association status={assoc.get('status')}")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ResourceNotFoundException":
                drift = True
                print(f"  reconcile: {app_id} association {assoc_id} not found")
            else:
                print(f"  reconcile: {app_id} check error: {e}")
                continue

        if not drift:
            continue

        # Mark RECONCILING to prevent concurrent repair executions.
        _registry.update_item(
            Key              = {"app_id": app_id},
            UpdateExpression = "SET lifecycle_state = :s, updated_at = :ts",
            ExpressionAttributeValues={
                ":s":  "RECONCILING",
                ":ts": int(time.time()),
            },
        )

        ts   = int(time.time())
        name = f"{app_id}-repair-{ts}"
        _sf.start_execution(
            stateMachineArn = SF_ARN,
            name            = name,
            input           = json.dumps({"ctx": {
                "app_id":             app_id,
                "fqdn":               record.get("fqdn", ""),
                "account_id":         account_id,
                "source_aws_account": account_id,
                "region":             record.get("region", REGION),
                "port":               int(record.get("port", 443)),
                "environment":        record.get("environment", "prod"),
                "enabled":            True,
                "revision":           int(record.get("desired_revision", 1)),
                "tries":              0,
                "repair":             True,
            }}),
        )
        print(f"  reconcile: started repair execution {name} for {app_id}")
        repaired += 1

    print(f"reconcile: checked {len(items)} records, started {repaired} repair(s)")
    return {"repaired": repaired}
