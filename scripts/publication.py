#!/usr/bin/env python3
"""
Publishes an application into the ZLAF Lattice service network and proves
the FQDN + TLS path: NetBird client → routing peer → endpoint → Lattice
service → existing ALB.

  python scripts/publication.py [--app app-c|app-d]        # build and verify
  python scripts/publication.py [--app app-c|app-d] --down # tear down

Requires:
  NETBIRD_API_TOKEN   NetBird management API token
  APP_C_PROFILE       AWS profile for account C (default: app-c)
  APP_D_PROFILE       AWS profile for account D (default: app-d)
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error

import boto3
from botocore.exceptions import ClientError

BASE  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB   = json.load(open(os.path.join(BASE, "lab.json")))
EVDIR = os.path.join(BASE, "evidence")
os.makedirs(EVDIR, exist_ok=True)

REGION   = LAB["region"]
NB_MGMT  = LAB["netbird"]["management_url"]
NB_TOKEN = os.environ.get("NETBIRD_API_TOKEN", "")

access = boto3.Session(region_name=REGION)


def ev(name):
    return os.path.join(EVDIR, name)


def dump(name, obj):
    with open(ev(name), "w") as f:
        json.dump(obj, f, indent=2, default=str)
    return obj


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"\n=== {msg} ===")


def nb(method, path, body=None):
    url  = f"{NB_MGMT}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Token {NB_TOKEN}")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"NetBird {method} {path}: {e.code} {e.read().decode()}")


def wait_status(get_fn, identifier, resource_name, target="ACTIVE",
                max_tries=36, interval=10):
    for _ in range(max_tries):
        r      = get_fn(identifier)
        status = r.get("status", "")
        if status == target:
            print(f" {status}")
            return r
        if "FAIL" in status:
            print(f" {status}")
            fail(f"{resource_name} reached {status}")
        print(".", end="", flush=True)
        time.sleep(interval)
    print(" timeout")
    fail(f"{resource_name} did not reach {target}")


def _app_session(app_id):
    env_key = "APP_C_PROFILE" if app_id == "app-c" else "APP_D_PROFILE"
    default = app_id
    return boto3.Session(profile_name=os.environ.get(env_key, default),
                         region_name=REGION)


# ── UP ─────────────────────────────────────────────────────────────────────

def up(app):
    app_id   = app["id"]
    fqdn     = app["fqdn"]
    alb_name = app["alb_name"]
    pub_file = f"{app_id}-publication.json"
    px       = f"{app_id}-"

    if os.path.exists(ev(pub_file)):
        fail(f"evidence/{pub_file} exists; run --down first")

    app_sess = _app_session(app_id)
    res      = json.load(open(ev("resources.json")))
    sn_arn   = res["service_network_arn"]
    vpc_id   = res["vpc"]
    ep_id    = res["endpoint"]
    ep_sub   = res["ep_subnet"]

    # ── 1. ALB ──────────────────────────────────────────────────────────────
    log(f"1. Locate {app_id} ALB")
    elb     = app_sess.client("elbv2")
    alb     = elb.describe_load_balancers(Names=[alb_name])["LoadBalancers"][0]
    alb_arn = alb["LoadBalancerArn"]
    alb_vpc = alb["VpcId"]
    alb_sg  = alb["SecurityGroups"][0]
    dump(f"{px}01-alb.json", alb)
    print(f"  {alb_name}: vpc={alb_vpc}  sg={alb_sg}")

    # ── 2. Permit Lattice prefix list on ALB SG :443 ────────────────────────
    log(f"2. Permit VPC Lattice prefix list on {app_id} ALB SG :443")
    ec2a    = app_sess.client("ec2")
    pl_resp = ec2a.describe_managed_prefix_lists(
        Filters=[
            {"Name": "prefix-list-name",
             "Values": [f"com.amazonaws.{REGION}.vpc-lattice"]},
            {"Name": "owner-id", "Values": ["AWS"]},
        ]
    )
    if not pl_resp["PrefixLists"]:
        fail(f"Lattice prefix list not found in {REGION}")
    pl_id = pl_resp["PrefixLists"][0]["PrefixListId"]
    try:
        ec2a.authorize_security_group_ingress(
            GroupId=alb_sg,
            IpPermissions=[{
                "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                "PrefixListIds": [{"PrefixListId": pl_id,
                                   "Description": "zlaf-lattice"}],
            }]
        )
        print(f"  {alb_sg} ← {pl_id} tcp/443: added")
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidPermission.Duplicate":
            raise
        print(f"  {alb_sg} ← {pl_id} tcp/443: already present")

    # ── 3. Lattice target group (ALB type, TCP/443) ──────────────────────────
    log(f"3. Lattice target group ({app_id}/ALB/TCP/443)")
    lat  = app_sess.client("vpc-lattice")
    tg   = lat.create_target_group(
        name=f"zlaf-{app_id}-tg",
        type="ALB",
        config={"port": 443, "protocol": "TCP", "vpcIdentifier": alb_vpc},
    )
    tg_arn = tg["arn"]
    tg_id  = tg["id"]
    dump(f"{px}03-tg.json", tg)
    lat.register_targets(
        targetGroupIdentifier=tg_id,
        targets=[{"id": alb_arn, "port": 443}],
    )
    print(f"  tg={tg_arn}")
    print(f"  target={alb_arn} :443")

    # ── 4. Lattice service with custom domain ────────────────────────────────
    log(f"4. Lattice service with custom domain ({fqdn})")
    svc = lat.create_service(
        name=f"zlaf-{app_id}",
        authType="NONE",
        customDomainName=fqdn,
    )
    svc_arn = svc["arn"]
    svc_id  = svc["id"]
    svc_dns = svc["dnsEntry"]["domainName"]
    dump(f"{px}04-service.json", svc)
    print(f"  service={svc_arn}")
    print(f"  lattice dns={svc_dns}  custom={fqdn}")

    print("  waiting ACTIVE", end="", flush=True)
    wait_status(
        lambda i: lat.get_service(serviceIdentifier=i),
        svc_id, "service"
    )

    # ── 5. TLS_PASSTHROUGH listener :443 ────────────────────────────────────
    log("5. TLS_PASSTHROUGH listener :443")
    lst = lat.create_listener(
        serviceIdentifier=svc_id,
        name="tls-passthrough-443",
        protocol="TLS_PASSTHROUGH",
        port=443,
        defaultAction={
            "forward": {
                "targetGroups": [{"targetGroupIdentifier": tg_id, "weight": 100}]
            }
        },
    )
    lst_arn = lst["arn"]
    lst_id  = lst["id"]
    dump(f"{px}05-listener.json", lst)
    print(f"  listener={lst_arn}")

    # ── 6. Associate service with service network ────────────────────────────
    log("6. Associate service with service network")
    assoc = lat.create_service_network_service_association(
        serviceIdentifier=svc_arn,
        serviceNetworkIdentifier=sn_arn,
    )
    assoc_id = assoc["id"]
    dump(f"{px}06-assoc.json", assoc)
    print(f"  assoc={assoc_id}", end="", flush=True)
    wait_status(
        lambda i: lat.get_service_network_service_association(
            serviceNetworkServiceAssociationIdentifier=i),
        assoc_id, "association"
    )

    # ── 7. Route 53 exact-FQDN private zone + apex record ───────────────────
    log(f"7. Route 53 private zone: exact-FQDN apex record for {fqdn}")
    ep_raw      = access.client("ec2").describe_vpc_endpoints(
        VpcEndpointIds=[ep_id]
    )["VpcEndpoints"][0]
    dns_entries = ep_raw.get("DnsEntries", [])
    dump(f"{px}07-ep.json", {"endpoint_id": ep_id, "dns_entries": dns_entries})

    alias_mode = "a_record"
    ep_dns = ep_hz = None
    if dns_entries and dns_entries[0].get("HostedZoneId"):
        ep_dns     = dns_entries[0]["DnsName"]
        ep_hz      = dns_entries[0]["HostedZoneId"]
        alias_mode = "alias"
    else:
        enis = access.client("ec2").describe_network_interfaces(
            Filters=[{"Name": "subnet-id", "Values": [ep_sub]}]
        )["NetworkInterfaces"]
        if not enis:
            fail("endpoint has neither DnsEntries nor an ENI in the endpoint subnet")
        ep_dns = enis[0]["PrivateIpAddress"]
        print(f"  endpoint has no alias-capable DnsEntries; using ENI IP {ep_dns}")

    print(f"  endpoint dns={ep_dns}  mode={alias_mode}")

    r53  = access.client("route53")
    zone = r53.create_hosted_zone(
        Name=f"{fqdn}.",
        HostedZoneConfig={"Comment": "zlaf split-view", "PrivateZone": True},
        CallerReference=f"zlaf-pub-{fqdn.replace('.', '-')}",
        VPC={"VPCRegion": REGION, "VPCId": vpc_id},
    )
    zone_id = zone["HostedZone"]["Id"].split("/")[-1]
    dump(f"{px}07-zone.json", zone)
    print(f"  zone={zone_id}")

    if alias_mode == "alias":
        rrset = {
            "Name": f"{fqdn}.",
            "Type": "A",
            "AliasTarget": {
                "HostedZoneId": ep_hz,
                "DNSName":      f"{ep_dns}.",
                "EvaluateTargetHealth": False,
            },
        }
    else:
        rrset = {
            "Name": f"{fqdn}.",
            "Type": "A",
            "TTL":  60,
            "ResourceRecords": [{"Value": ep_dns}],
        }

    r53.change_resource_record_sets(
        HostedZoneId=zone_id,
        ChangeBatch={"Changes": [{"Action": "CREATE", "ResourceRecordSet": rrset}]},
    )
    print(f"  apex {alias_mode}: {fqdn} → {ep_dns}")

    # ── 8. NetBird exact-FQDN domain route ──────────────────────────────────
    log(f"8. NetBird exact-FQDN domain route for {fqdn}")
    groups     = nb("GET", "/api/groups")
    access_gid = next(g["id"] for g in groups if g["name"] == "zlaf-access")
    nb_route   = nb("POST", "/api/routes", {
        "description": f"zlaf {fqdn} tcp/443",
        "network_id":  f"zlaf-{app_id}-domain",
        "domains":     [fqdn],
        "peer":        res["nb_peer"],
        "enabled":     True,
        "masquerade":  False,
        "metric":      9998,
        "groups":      [access_gid],
    })
    nb_route_id = nb_route.get("id")
    dump(f"{px}08-nb-route.json", nb_route)
    print(f"  nb route={nb_route_id}")

    pub = {
        "app_id":      app_id,
        "fqdn":        fqdn,
        "alias_mode":  alias_mode,
        "alb_sg":      alb_sg,
        "lattice_pl":  pl_id,
        "tg_arn":      tg_arn,   "tg_id":   tg_id,
        "svc_arn":     svc_arn,  "svc_id":  svc_id,  "svc_dns": svc_dns,
        "lst_arn":     lst_arn,  "lst_id":  lst_id,
        "assoc_id":    assoc_id,
        "zone_id":     zone_id,
        "ep_dns":      ep_dns,   "ep_hz":   ep_hz,
        "nb_route_id": nb_route_id,
    }
    dump(pub_file, pub)

    _verify(res, pub, app_sess)


# ── VERIFY ──────────────────────────────────────────────────────────────────

def _verify(res, pub, app_sess):
    ssm    = access.client("ssm")
    inst   = res["peer_instance"]
    fqdn   = pub["fqdn"]
    app_id = pub["app_id"]
    marker = f"ZLAF-POC-{app_id.upper().replace('-', '')}"
    px     = f"{app_id}-"

    def ssm_run(cmd, label, timeout=60):
        r   = ssm.send_command(
            InstanceIds=[inst],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [cmd]},
        )
        cid      = r["Command"]["CommandId"]
        deadline = time.time() + timeout + 30
        while time.time() < deadline:
            time.sleep(5)
            o = ssm.get_command_invocation(CommandId=cid, InstanceId=inst)
            if o["Status"] not in ("Pending", "InProgress", "Delayed"):
                break
        dump(f"{px}v-{label}.json", o)
        return (o.get("StandardOutputContent", ""),
                o.get("StandardErrorContent", ""),
                o["Status"])

    log(f"V1. DNS from routing peer: {fqdn} resolves via access-VPC private zone")
    out, _, _ = ssm_run(
        f"python3 -c \"import socket; print(socket.gethostbyname('{fqdn}'))\"",
        "dns-peer"
    )
    print(f"  {fqdn} → {out.strip()[:80] or '(empty)'}")

    log(f"V2. Route 53: no private zone override in {app_id} account")
    app_r53   = app_sess.client("route53")
    app_zones = app_r53.list_hosted_zones_by_name(DNSName=fqdn, MaxItems="5")
    dump(f"{px}v-app-r53.json", app_zones)
    override = [z for z in app_zones.get("HostedZones", [])
                if z["Config"]["PrivateZone"] and fqdn in z["Name"]]
    print(f"  {app_id} private zones for {fqdn}: {len(override)} (expect 0)")

    log(f"V3. HTTPS probe: {fqdn}, no --resolve, no cert bypass")
    curl_cmd = (
        f"curl -sv --max-time 20 "
        f"-H 'X-Zlaf-Probe: {marker}' "
        f"https://{fqdn}/ 2>&1"
    )
    out3, err3, st3 = ssm_run(curl_cmd, "https", timeout=30)
    combined = out3 + err3
    dump(f"{px}v-https.json", {"cmd": curl_cmd, "output": combined, "ssm_status": st3})

    cn_m   = re.search(r'subject:.*?CN\s*=\s*([^\s,\r\n/]+)', combined)
    http_m = re.search(r'< HTTP/[12][. ]\d+ (\d+)', combined)
    tls_cn = cn_m.group(1)   if cn_m   else "(not extracted)"
    http_s = http_m.group(1) if http_m else "(not found)"
    print(f"  TLS CN:  {tls_cn}")
    print(f"  HTTP:    {http_s}")
    print(f"  SSM:     {st3}")

    if st3 == "Success" and http_m:
        print(f"  RESULT: TLS_PASSTHROUGH + ALB path PROVEN via {fqdn}")
    else:
        print("  RESULT: HTTPS probe did not complete — see evidence.")
        print("  If TLS_PASSTHROUGH listener + ALB target is unsupported,")
        print("  the next step is Resource Configuration (VISION.md §10).")

    log("V4. Denied-identity: drop rule present in policy layer")
    policies   = nb("GET", "/api/policies")
    dump(f"{px}v-nb-policies.json", policies)
    deny_rules = [r for p in policies
                  for r in p.get("rules", []) if r.get("action") == "drop"]
    print(f"  drop rules: {len(deny_rules)} (expect ≥1)")

    log(f"V5. Route inventory: no subnet-wide resource; exact-FQDN route for {fqdn}")
    routes = nb("GET", "/api/routes")
    dump(f"{px}v-nb-routes.json", routes)
    broad  = [r for r in routes
              if r.get("network") in ("0.0.0.0/0", "10.0.0.0/8", "10.0.0.0/16")]
    domain = [r for r in routes if fqdn in (r.get("domains") or [])]
    print(f"  broad subnet routes:   {len(broad)} (expect 0)")
    print(f"  exact-FQDN routes for {fqdn}: {len(domain)} (expect 1)")

    print(f"\nEvidence: {EVDIR}/{px}v-*.json")


# ── DOWN ────────────────────────────────────────────────────────────────────

def down(app):
    app_id   = app["id"]
    pub_file = f"{app_id}-publication.json"
    pub_path = ev(pub_file)
    if not os.path.exists(pub_path):
        fail(f"evidence/{pub_file} not found; run without --down first")
    pub = json.load(open(pub_path))

    app_sess = _app_session(app_id)
    lat  = app_sess.client("vpc-lattice")
    r53  = access.client("route53")
    ec2a = app_sess.client("ec2")
    px   = f"{app_id}-"

    log("1. NetBird domain route")
    if pub.get("nb_route_id"):
        try:
            nb("DELETE", f"/api/routes/{pub['nb_route_id']}")
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    log("2. Route 53 apex record and hosted zone")
    if pub.get("zone_id"):
        try:
            if pub.get("alias_mode") == "alias":
                rrset = {
                    "Name": f"{pub['fqdn']}.",
                    "Type": "A",
                    "AliasTarget": {
                        "HostedZoneId": pub["ep_hz"],
                        "DNSName":      f"{pub['ep_dns']}.",
                        "EvaluateTargetHealth": False,
                    },
                }
            else:
                rrset = {
                    "Name": f"{pub['fqdn']}.",
                    "Type": "A",
                    "TTL":  60,
                    "ResourceRecords": [{"Value": pub["ep_dns"]}],
                }
            r53.change_resource_record_sets(
                HostedZoneId=pub["zone_id"],
                ChangeBatch={"Changes": [{"Action": "DELETE",
                                          "ResourceRecordSet": rrset}]},
            )
        except Exception as e:
            print(f"  warning deleting record: {e}")
        try:
            r53.delete_hosted_zone(Id=pub["zone_id"])
        except Exception as e:
            print(f"  warning deleting zone: {e}")
    print("  done")

    log("3. Service-network association")
    if pub.get("assoc_id"):
        try:
            lat.delete_service_network_service_association(
                serviceNetworkServiceAssociationIdentifier=pub["assoc_id"]
            )
            for _ in range(30):
                try:
                    a = lat.get_service_network_service_association(
                        serviceNetworkServiceAssociationIdentifier=pub["assoc_id"]
                    )
                    if "FAIL" in a.get("status", ""):
                        print(f"  warning: association {a['status']}")
                        break
                    time.sleep(10)
                except ClientError as e:
                    if e.response["Error"]["Code"] == "ResourceNotFoundException":
                        break
                    raise
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    log("4. Listener")
    if pub.get("svc_id") and pub.get("lst_id"):
        try:
            lat.delete_listener(
                serviceIdentifier=pub["svc_id"],
                listenerIdentifier=pub["lst_id"],
            )
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    log("5. Service")
    if pub.get("svc_id"):
        try:
            lat.delete_service(serviceIdentifier=pub["svc_id"])
            for _ in range(30):
                try:
                    lat.get_service(serviceIdentifier=pub["svc_id"])
                    time.sleep(10)
                except ClientError as e:
                    if e.response["Error"]["Code"] == "ResourceNotFoundException":
                        break
                    raise
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    log("6. Target group")
    if pub.get("tg_id"):
        alb_ev = ev(f"{px}01-alb.json")
        try:
            alb_data = json.load(open(alb_ev))
            lat.deregister_targets(
                targetGroupIdentifier=pub["tg_id"],
                targets=[{"id": alb_data["LoadBalancerArn"], "port": 443}],
            )
            time.sleep(15)
            lat.delete_target_group(targetGroupIdentifier=pub["tg_id"])
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    log("7. ALB SG rule")
    if pub.get("alb_sg") and pub.get("lattice_pl"):
        try:
            ec2a.revoke_security_group_ingress(
                GroupId=pub["alb_sg"],
                IpPermissions=[{
                    "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                    "PrefixListIds": [{"PrefixListId": pub["lattice_pl"]}],
                }]
            )
        except Exception as e:
            print(f"  warning: {e}")
    print("  done")

    os.remove(pub_path)
    print("\nTeardown complete.")


# ── MAIN ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--app", default="app-c", choices=["app-c", "app-d"],
                    help="application to publish (default: app-c)")
    ap.add_argument("--down", action="store_true",
                    help="tear down publication resources")
    args = ap.parse_args()
    if not NB_TOKEN:
        fail("NETBIRD_API_TOKEN is not set")

    app_idx = 0 if args.app == "app-c" else 1
    app     = LAB["applications"][app_idx]

    if args.down:
        down(app)
    else:
        up(app)
