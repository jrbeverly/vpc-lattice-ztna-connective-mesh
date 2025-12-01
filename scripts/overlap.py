#!/usr/bin/env python3
"""
Proves two overlapping-CIDR application VPCs share the ZLAF access path.

Requires app-c to be published first (evidence/app-c-publication.json).

  python scripts/overlap.py          # publish app-d and run full proof
  python scripts/overlap.py --down   # tear down app-d publication

Requires:
  NETBIRD_API_TOKEN   NetBird management API token
  APP_D_PROFILE       AWS profile for account D (default: app-d)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

import boto3

BASE  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB   = json.load(open(os.path.join(BASE, "lab.json")))
EVDIR = os.path.join(BASE, "evidence")
os.makedirs(EVDIR, exist_ok=True)

REGION   = LAB["region"]
NB_MGMT  = LAB["netbird"]["management_url"]
NB_TOKEN = os.environ.get("NETBIRD_API_TOKEN", "")

APP_C = LAB["applications"][0]
APP_D = LAB["applications"][1]

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


def snapshot(tag, res):
    ec2 = access.client("ec2")
    lat = access.client("vpc-lattice")
    ram = access.client("ram")

    vpc_id = res["vpc"]
    ep_id  = res["endpoint"]
    sn_arn = res["service_network_arn"]

    rts = ec2.describe_route_tables(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["RouteTables"]

    ep = ec2.describe_vpc_endpoints(
        VpcEndpointIds=[ep_id]
    )["VpcEndpoints"][0]

    shares = ram.list_resources(
        resourceOwner="SELF",
        resourceType="vpc-lattice:ServiceNetwork",
    ).get("resources", [])

    assoc_pages = lat.get_paginator("list_service_network_service_associations")
    assocs = []
    for page in assoc_pages.paginate(serviceNetworkIdentifier=sn_arn):
        assocs.extend(page.get("items", []))

    peering = [
        r for rt in rts for r in rt.get("Routes", [])
        if r.get("GatewayId", "").startswith("pcx-")
    ]
    tgw = [
        r for rt in rts for r in rt.get("Routes", [])
        if r.get("TransitGatewayId")
    ]
    route_cidrs = sorted(
        r["DestinationCidrBlock"] for rt in rts
        for r in rt.get("Routes", []) if "DestinationCidrBlock" in r
    )

    state = {
        "tag": tag,
        "endpoint_id":    ep["VpcEndpointId"],
        "endpoint_state": ep["State"],
        "endpoint_dns":   ep.get("DnsEntries", []),
        "route_cidrs":    route_cidrs,
        "peering_routes": len(peering),
        "tgw_routes":     len(tgw),
        "ram_arns":       sorted(r.get("arn", "") for r in shares),
        "sn_associations": [
            {"id": a["id"], "serviceArn": a["serviceArn"], "status": a["status"]}
            for a in assocs
        ],
    }
    dump(f"overlap-{tag}.json", state)
    return state


def compare(before, after):
    log("COMPARE: access infrastructure before → after app-d registration")
    ok = True

    if before["endpoint_id"] != after["endpoint_id"]:
        print(f"  FAIL endpoint changed: {before['endpoint_id']} → {after['endpoint_id']}")
        ok = False
    else:
        print(f"  endpoint:      {after['endpoint_id']} UNCHANGED")

    if before["route_cidrs"] != after["route_cidrs"]:
        added   = set(after["route_cidrs"]) - set(before["route_cidrs"])
        removed = set(before["route_cidrs"]) - set(after["route_cidrs"])
        print(f"  WARN route tables changed: +{sorted(added)} -{sorted(removed)}")
    else:
        print(f"  route tables:  {len(after['route_cidrs'])} routes UNCHANGED")

    print(f"  peering routes: {after['peering_routes']} (expect 0)")
    print(f"  TGW routes:     {after['tgw_routes']} (expect 0)")

    if before["ram_arns"] != after["ram_arns"]:
        print(f"  WARN RAM shares changed: {before['ram_arns']} → {after['ram_arns']}")
    else:
        print(f"  RAM shares:    {len(after['ram_arns'])} UNCHANGED")

    b_ids = {a["id"] for a in before["sn_associations"]}
    a_ids = {a["id"] for a in after["sn_associations"]}
    new   = a_ids - b_ids
    print(f"  SN associations: {len(b_ids)} → {len(a_ids)} "
          f"(+{len(new)} new — {new or 'none'})")
    if len(a_ids) != len(b_ids) + 1:
        print("  WARN: expected exactly one new association for app-d")

    return ok


def ssm_run(inst, cmd, label, timeout=60):
    ssm = access.client("ssm")
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
    dump(f"overlap-{label}.json", o)
    return (o.get("StandardOutputContent", ""),
            o.get("StandardErrorContent", ""),
            o["Status"])


def dual_probe(res):
    inst   = res["peer_instance"]
    fqdn_c = APP_C["fqdn"]
    fqdn_d = APP_D["fqdn"]

    log(f"DUAL-1. app-d FQDN unresolvable before publication")
    out, _, _ = ssm_run(
        inst,
        f"python3 -c \"import socket; print(socket.gethostbyname('{fqdn_d}'))\" "
        "2>/dev/null || echo NXDOMAIN",
        "pre-dns-d"
    )
    print(f"  {fqdn_d} (before) → {out.strip()[:80] or '(empty)'}")

    # Publish app-d
    log("DUAL-2. Publish app-d")
    pub_script = os.path.join(BASE, "scripts", "publication.py")
    subprocess.run(
        [sys.executable, pub_script, "--app", "app-d"],
        check=True,
        env=os.environ,
    )

    log(f"DUAL-3. Both FQDNs resolve to the same endpoint IP")
    out_c, _, _ = ssm_run(
        inst,
        f"python3 -c \"import socket; print(socket.gethostbyname('{fqdn_c}'))\"",
        "dns-c"
    )
    out_d, _, _ = ssm_run(
        inst,
        f"python3 -c \"import socket; print(socket.gethostbyname('{fqdn_d}'))\"",
        "dns-d"
    )
    ip_c = out_c.strip()
    ip_d = out_d.strip()
    print(f"  {fqdn_c} → {ip_c}")
    print(f"  {fqdn_d} → {ip_d}")
    same_ip = ip_c == ip_d and ip_c != ""
    print(f"  same endpoint IP: {same_ip} (both zones point to same endpoint)")

    log(f"DUAL-4. HTTPS probe: {fqdn_c} — cert and marker")
    curl_c = (
        f"curl -sv --max-time 20 "
        f"-H 'X-Zlaf-Probe: ZLAF-POC-APPC' "
        f"https://{fqdn_c}/ 2>&1"
    )
    out3c, err3c, st3c = ssm_run(inst, curl_c, "https-c", timeout=30)
    comb_c = out3c + err3c
    dump("overlap-https-c.json", {"cmd": curl_c, "output": comb_c, "ssm_status": st3c})
    cn_c   = re.search(r'subject:.*?CN\s*=\s*([^\s,\r\n/]+)', comb_c)
    http_c = re.search(r'< HTTP/[12][. ]\d+ (\d+)', comb_c)
    print(f"  TLS CN:  {cn_c.group(1) if cn_c else '(not extracted)'}")
    print(f"  HTTP:    {http_c.group(1) if http_c else '(not found)'}")
    print(f"  SSM:     {st3c}")

    log(f"DUAL-5. HTTPS probe: {fqdn_d} — cert and marker")
    curl_d = (
        f"curl -sv --max-time 20 "
        f"-H 'X-Zlaf-Probe: ZLAF-POC-APPD' "
        f"https://{fqdn_d}/ 2>&1"
    )
    out3d, err3d, st3d = ssm_run(inst, curl_d, "https-d", timeout=30)
    comb_d = out3d + err3d
    dump("overlap-https-d.json", {"cmd": curl_d, "output": comb_d, "ssm_status": st3d})
    cn_d   = re.search(r'subject:.*?CN\s*=\s*([^\s,\r\n/]+)', comb_d)
    http_d = re.search(r'< HTTP/[12][. ]\d+ (\d+)', comb_d)
    print(f"  TLS CN:  {cn_d.group(1) if cn_d else '(not extracted)'}")
    print(f"  HTTP:    {http_d.group(1) if http_d else '(not found)'}")
    print(f"  SSM:     {st3d}")

    cn_c_val = cn_c.group(1) if cn_c else ""
    cn_d_val = cn_d.group(1) if cn_d else ""
    cns_distinct = cn_c_val != cn_d_val
    print(f"\n  Certificates distinct: {cns_distinct}  "
          f"(app-c CN={cn_c_val!r}, app-d CN={cn_d_val!r})")

    # Cross-SNI isolation probe
    # Both FQDNs resolve to the same endpoint IP (proven in DUAL-3).
    # A client that can reach the endpoint by IP (e.g. from inside the access VPC)
    # can present any SNI and reach the matching service — DNS is not the only gate.
    # This probe measures that boundary explicitly.
    log("DUAL-6. Cross-SNI isolation probe (force-resolve to shared endpoint IP)")
    if same_ip and ip_c:
        # Force curl to connect to the shared endpoint IP for the D FQDN.
        # Equivalent to a client that has no domain route for D but knows the endpoint IP.
        cross_cmd = (
            f"curl -sv --max-time 20 "
            f"--resolve {fqdn_d}:443:{ip_c} "
            f"-H 'X-Zlaf-Probe: ZLAF-CROSS-SNI' "
            f"https://{fqdn_d}/ 2>&1"
        )
        out_x, err_x, st_x = ssm_run(inst, cross_cmd, "cross-sni", timeout=30)
        comb_x = out_x + err_x
        dump("overlap-cross-sni.json", {"cmd": cross_cmd, "output": comb_x, "ssm_status": st_x})
        cn_x   = re.search(r'subject:.*?CN\s*=\s*([^\s,\r\n/]+)', comb_x)
        http_x = re.search(r'< HTTP/[12][. ]\d+ (\d+)', comb_x)
        print(f"  TLS CN:  {cn_x.group(1) if cn_x else '(not extracted)'}")
        print(f"  HTTP:    {http_x.group(1) if http_x else '(not found)'}")
        print(f"  SSM:     {st_x}")
        print()
        print("  BOUNDARY: VPC Lattice routes by SNI (custom domain), not IP.")
        print("  Any host in the access VPC can reach any service-network service")
        print("  by connecting to the shared endpoint IP with the target SNI.")
        print("  The ZTNA domain route is the DNS-layer gate, not a TCP gate.")
        print("  A C-only authorized client without a D domain route cannot resolve")
        print(f"  {fqdn_d} through the routing peer, but can still reach App D")
        print("  if it obtains the endpoint IP by other means.")
        print("  Resolution: Lattice auth policies or network ACLs on the endpoint")
        print("  subnet are the appropriate layer for per-service TCP isolation.")
    else:
        print("  SKIP: FQDNs resolved to different IPs or resolution failed.")

    log("DUAL-7. NetBird route inventory: no broad subnet routes")
    routes = nb("GET", "/api/routes")
    dump("overlap-nb-routes.json", routes)
    broad  = [r for r in routes
              if r.get("network") in ("0.0.0.0/0", "10.0.0.0/8", "10.0.0.0/16")]
    dom_c  = [r for r in routes if fqdn_c in (r.get("domains") or [])]
    dom_d  = [r for r in routes if fqdn_d in (r.get("domains") or [])]
    print(f"  broad subnet routes: {len(broad)} (expect 0)")
    print(f"  domain routes for {fqdn_c}: {len(dom_c)} (expect 1)")
    print(f"  domain routes for {fqdn_d}: {len(dom_d)} (expect 1)")


# ── UP / DOWN ────────────────────────────────────────────────────────────────

def up():
    pub_c = ev("app-c-publication.json")
    if not os.path.exists(pub_c):
        fail("evidence/app-c-publication.json not found; "
             "publish app-c first: python3 scripts/publication.py --app app-c")

    pub_d = ev("app-d-publication.json")
    if os.path.exists(pub_d):
        fail("evidence/app-d-publication.json exists; run --down first")

    res = json.load(open(ev("resources.json")))

    log("SNAPSHOT: access infrastructure before app-d registration")
    before = snapshot("before", res)
    print(f"  route CIDRs:    {before['route_cidrs']}")
    print(f"  endpoint:       {before['endpoint_id']}")
    print(f"  RAM arns:       {len(before['ram_arns'])}")
    print(f"  SN assocs:      {len(before['sn_associations'])}")

    dual_probe(res)

    log("SNAPSHOT: access infrastructure after app-d registration")
    after = snapshot("after", res)
    print(f"  SN assocs:      {len(after['sn_associations'])}")

    compare(before, after)

    print(f"\nEvidence: {EVDIR}/overlap-*.json")


def down():
    pub_script = os.path.join(BASE, "scripts", "publication.py")
    subprocess.run(
        [sys.executable, pub_script, "--app", "app-d", "--down"],
        check=True,
        env=os.environ,
    )


# ── MAIN ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--down", action="store_true",
                    help="tear down app-d publication")
    args = ap.parse_args()
    if not NB_TOKEN:
        fail("NETBIRD_API_TOKEN is not set")
    if args.down:
        down()
    else:
        up()
