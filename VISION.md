# Zero-Trust Lattice Access Fabric

## Vision, Architecture, and Service Management Model

**Status:** Vision / target-state architecture
**Primary technologies:** Palo Alto Prisma Access ZTNA Connector, Amazon VPC Lattice, AWS Resource Access Manager, Amazon Route 53 Resolver, Amazon EventBridge, AWS Organizations
**Working name:** Zero-Trust Lattice Access Fabric (ZLAF)

---

# 1. Executive Summary

The Zero-Trust Lattice Access Fabric is a model for providing authenticated user access to private applications distributed across large numbers of AWS accounts and VPCs without building a traditional centralized routed network.

The architecture deliberately rejects the assumption that private application access requires VPC peering, Transit Gateway routing, CIDR coordination, centralized route tables, or a private WAN connecting application VPCs.

Instead, the architecture separates three concerns:

**Identity and user access** are provided by a Zero Trust Network Access platform such as Palo Alto Prisma Access ZTNA Connector.

**Application connectivity** is provided by Amazon VPC Lattice.

**Application registration and lifecycle management** are provided by an automated service registry and event-driven control plane.

The intended result is:

> An application can become privately accessible to authorized users by declaring that it should participate in the access fabric, without an application developer designing networking, modifying application DNS names, building routes, requesting IP space, or manually configuring the ZTNA platform.

Applications retain their existing names such as:

`website.example.ca`

and their existing private infrastructure, such as an internal Application Load Balancer.

The access fabric creates an alternative, centrally controlled path to that same application:

```text
User
 │
 ▼
Prisma Access
 │
 ▼
ZTNA Connector
 │
 ▼
Central AWS VPC
 │
 ▼
VPC Lattice Service-Network Endpoint
 │
 ▼
Prod Access Service Network
 │
 ▼
Published Application
 │
 ▼
Existing private ALB
 │
 ▼
Application
```

The application VPC does not become part of a central routed network.

The application's CIDR range is therefore largely irrelevant to the central access architecture. AWS explicitly identifies overlapping CIDR support as a property of VPC Lattice.

The architecture is primarily a **service access fabric**, not a network connectivity fabric.

---

# 2. Vision

The long-term vision is:

> Any eligible private AWS application should be able to opt into secure enterprise access through metadata alone.

The application owner should not need to understand:

- Prisma Access internals
- ZTNA Connector deployment
- VPC Lattice
- Route 53 split-view DNS
- AWS RAM
- connector routing
- central network CIDRs
- Transit Gateway
- cross-account networking
- certificate duplication
- central firewall rules
- service-network associations

Instead, the application should satisfy a published platform contract.

For example, an application might expose metadata such as:

```yaml
access:
  private-user-access: true
  environment: prod
  fqdn: website.example.ca
  protocol: tcp
  port: 443
  exposure: enterprise-ztna
```

or equivalent AWS resource tags:

```text
EnterpriseAccess        = enabled
EnterpriseAccessFQDN    = website.example.ca
EnterpriseAccessPort    = 443
EnterpriseAccessClass   = prod
```

Everything else should be generated.

The platform discovers or receives that declaration, validates it, creates the required AWS Lattice resources, publishes the corresponding ZTNA target, establishes the required DNS steering, verifies that the complete path works, and records the application in a central registry.

Removing the declaration should initiate the reverse lifecycle.

---

# 3. Architectural Principle: Publish Services, Do Not Join Networks

Traditional private-access designs commonly begin by connecting networks:

```text
VPC A ──┐
VPC B ──┼── Transit Gateway ── Security VPC
VPC C ──┘
```

This creates a network topology that must understand:

- VPC CIDRs
- route propagation
- overlapping address space
- attachment ownership
- route isolation
- routing domains
- segmentation
- network appliances
- inspection paths
- NAT
- regional and interregional routing

The proposed architecture instead works at the service boundary:

```text
                         ACCESS FABRIC
                              │
                ┌─────────────┼─────────────┐
                │             │             │
                ▼             ▼             ▼
             Service A     Service B     Service C
                │             │             │
                ▼             ▼             ▼
              VPC A         VPC B         VPC C
```

VPC A, VPC B, and VPC C do not need routes to each other.

They may even contain identical address space:

```text
VPC A = 10.0.0.0/16
VPC B = 10.0.0.0/16
VPC C = 10.0.0.0/16
```

The central system requests a service, not an IP topology.

This is the central design principle of the architecture.

---

# 4. Architectural Domains

The architecture should be divided into three distinct administrative domains.

## 4.1 Central Security / Access Account

This account is intentionally sensitive.

It contains the runtime components through which private-user traffic enters AWS.

Typical regional components are:

```text
Central Security Account

us-east-1
├── Access VPC
├── ZTNA Connector Group
├── Route 53 Resolver
├── Service-Network VPC Endpoint
└── Prod Access Lattice Service Network

ca-central-1
├── Access VPC
├── ZTNA Connector Group
├── Route 53 Resolver
├── Service-Network VPC Endpoint
└── Prod Access Lattice Service Network

eu-west-1
├── Access VPC
├── ZTNA Connector Group
├── Route 53 Resolver
├── Service-Network VPC Endpoint
└── Prod Access Lattice Service Network
```

VPC Lattice resources are regional AWS resources, as reflected in their regional ARNs and regional API endpoints. The architecture should therefore create a regional access fabric rather than pretending that a single global Lattice service network exists.

The security account should contain as little application-specific control-plane logic as practical.

It should primarily be a **runtime access plane**.

---

## 4.2 Central Service Registry / Orchestration Account

This should be a separate account.

It contains the intelligence of the platform rather than the user-data path.

Its responsibilities include:

```text
Application discovery
        │
        ▼
Registration intake
        │
        ▼
Validation
        │
        ▼
Desired-state registry
        │
        ▼
Provisioning orchestration
        │
        ├── Application account
        │
        ├── Security account
        │
        ├── Palo Alto API
        │
        └── DNS configuration
        │
        ▼
Verification
        │
        ▼
Monitoring / reconciliation
```

This account can contain:

- EventBridge custom event bus
- SQS queues
- Step Functions workflows
- Lambda functions
- DynamoDB application registry
- CloudWatch dashboards
- audit logs
- dead-letter queues
- deployment state
- validation logic
- application inventory
- notification integrations

Cross-account EventBridge is explicitly supported. Event buses can use resource policies to allow specific AWS accounts or an entire AWS Organization to submit events. AWS recommends IAM roles for cross-account event-bus targets so that organizational controls such as SCPs remain applicable.

This separation prevents the sensitive security account from becoming an enterprise automation hub.

---

## 4.3 Application Accounts

Application accounts remain responsible for their applications.

For example:

```text
Account C
│
├── VPC
│
├── application
│
├── internal ALB
│
├── normal Route 53 private DNS
│
└── generated Lattice publication resources
```

The application team owns:

```text
website.example.ca
```

and might already have:

```text
website.example.ca
        │
        ▼
internal-alb-123.elb.amazonaws.com
        │
        ▼
application targets
```

The access platform does not require them to rename this application.

The access platform also does not require the application VPC to become routable from the security account.

---

# 5. Canonical Architecture

The complete logical architecture is:

```text
                        ENTERPRISE USER
                              │
                              │ https://website.example.ca
                              ▼
                    Palo Alto Prisma Access
                              │
                     application identified
                              │
                              ▼
                         ZTNA Connector
                              │
         ┌────────────────────┴─────────────────────┐
         │          CENTRAL SECURITY ACCOUNT        │
         │                                          │
         │             Regional Access VPC          │
         │                    │                     │
         │                    │ DNS                 │
         │                    ▼                     │
         │             Route 53 Resolver            │
         │                    │                     │
         │                    │                     │
         │                    ▼                     │
         │       Service-Network VPC Endpoint       │
         │                    │                     │
         │                    ▼                     │
         │       VPC Lattice "Prod Access"          │
         └────────────────────┬─────────────────────┘
                              │
                         AWS Lattice
                              │
                  no conventional VPC route
                              │
         ┌────────────────────▼─────────────────────┐
         │                 ACCOUNT C                │
         │                                          │
         │       Generated application exposure     │
         │                                          │
         │        Lattice Service / Resource        │
         │                    │                     │
         │                    ▼                     │
         │          Existing Internal ALB           │
         │                    │                     │
         │                    ▼                     │
         │               Application                │
         │                                          │
         │ Existing application DNS remains:        │
         │ website.example.ca → internal ALB        │
         └──────────────────────────────────────────┘


              CONTROL PLANE — SEPARATE ACCOUNT

         ┌──────────────────────────────────────────┐
         │        SERVICE REGISTRY ACCOUNT          │
         │                                          │
Event ──►│ EventBridge                              │
         │      │                                   │
         │      ▼                                   │
         │ Registration Controller                  │
         │      │                                   │
         │      ▼                                   │
         │ Desired-State Registry                   │
         │      │                                   │
         │      ▼                                   │
         │ Orchestration / Step Functions           │
         │      │                                   │
         │      ├──► Account C provisioner          │
         │      ├──► Security account provisioner   │
         │      ├──► ZTNA registration              │
         │      └──► verification                   │
         └──────────────────────────────────────────┘
```

This is the canonical architecture the rest of the document describes.

---

# 6. The VPC Lattice Layer

## 6.1 Service Network

Each relevant region contains a centrally owned Lattice Service Network such as:

```text
prod-access-ca-central-1
prod-access-us-east-1
prod-access-eu-west-1
```

A service network is a logical boundary containing services and resource configurations. VPCs may consume those resources by connecting through a VPC association or a service-network VPC endpoint.

The access VPC uses the **service-network VPC endpoint** model.

AWS documents that this endpoint provides private access to the services and resources associated with the service network.

The architecture intentionally prefers this over attaching every application VPC to the service network as a client.

The central access VPC is the consumer.

The application accounts are providers.

---

# 7. AWS RAM Model

The centrally owned `Prod Access` service network is marked shareable at creation time.

AWS requires the sharing decision for a service network to be made when it is created; the setting is immutable afterward.

It is then distributed through AWS Resource Access Manager.

For example:

```text
Security Account
      │
      │ owns
      ▼
prod-access-ca-central-1
      │
      │ AWS RAM
      ▼
Production OU
      │
      ├── Account A
      ├── Account B
      └── Account C
```

AWS RAM supports sharing VPC Lattice:

- service networks
- services
- resource configurations

across AWS accounts.

If AWS Organizations sharing is enabled, member accounts can automatically receive access to shared Lattice entities rather than manually accepting individual RAM invitations.

RAM sharing grants the ability to participate.

It does **not** publish applications automatically.

That distinction is critical.

Account C merely receiving access to `Prod Access` does not expose anything inside Account C.

An explicit service or resource association must still be created.

---

# 8. Application Publication

Assume Account C contains:

```text
website.example.ca
```

behind:

```text
internal ALB
```

An application becomes available through the fabric only after the platform generates an application publication object.

There are two possible AWS Lattice publication models.

---

# 9. Publication Model A — VPC Lattice Service

The traditional Lattice model is:

```text
Lattice Service
      │
      ▼
Listener
      │
      ▼
Target Group
      │
      ▼
Application target
```

AWS supports an internal Application Load Balancer as a VPC Lattice target. The Lattice target group and ALB must reside in the same account and VPC.

Therefore the generated Lattice service components naturally belong in Account C:

```text
Account C

website.example.ca
       │
       ▼
Lattice Service
       │
       ▼
Listener
       │
       ▼
Lattice Target Group
       │
       ▼
existing internal ALB
```

The platform then associates that service with the centrally owned `Prod Access` service network.

VPC Lattice explicitly supports associating services with service networks so that clients connected to the network can call those services.

---

# 10. Publication Model B — Resource Configuration

Newer VPC Lattice resource configurations provide another potentially useful model.

A resource configuration can represent:

- a domain-name target
- an IP address
- supported AWS resource types

and can be made reachable across VPCs and accounts through a resource gateway and service network.

Resource configurations currently operate using TCP and can define allowed port ranges.

They also provide important private-DNS capabilities.

A consumer can enable private DNS and select policies such as:

```text
VERIFIED_DOMAINS_ONLY
ALL_DOMAINS
VERIFIED_DOMAINS_AND_SPECIFIED_DOMAINS
```

VPC Lattice can then provision the necessary private hosted zones on behalf of the consumer. AWS recommends `VERIFIED_DOMAINS_ONLY` as a restrictive default.

This model should be evaluated alongside traditional Lattice Services during implementation.

The architectural abstraction should therefore be:

```text
Application Publication
```

rather than hard-coding the platform registry around:

```text
Lattice Service
```

The registry can determine whether a publication is implemented as a Lattice Service or Resource Configuration.

---

# 11. DNS Strategy

DNS is one of the most important architectural details.

The fundamental requirement is:

> The application's identity must not change simply because it is being accessed remotely.

If the application is:

```text
website.example.ca
```

then an authorized remote user must continue using:

```text
https://website.example.ca
```

The architecture should not introduce names such as:

```text
website.ztna.example.ca
website.lattice.example.ca
website.remote.example.ca
```

unless an application explicitly chooses them.

---

# 12. Split-View DNS

Within Account C, the application's existing DNS remains untouched:

```text
ACCOUNT C DNS

website.example.ca
       │
       ▼
existing internal ALB
```

Within the ZTNA access VPC, the same FQDN resolves to the access-fabric representation:

```text
CENTRAL ACCESS VPC DNS

website.example.ca
       │
       ▼
Lattice publication
```

Therefore:

```text
same name
different path
same final application
```

This is conventional split-view DNS behavior.

The split does not change the identity of the application.

It changes only its network entry path.

---

# 13. Avoid Broad Shadow Zones Where Possible

The access platform should not unnecessarily create an incomplete private hosted zone such as:

```text
example.ca
```

and then manually duplicate a large corporate namespace.

Instead, its generated DNS state should be narrowly scoped to applications participating in ZTNA.

Conceptually:

```text
ZTNA APPLICATION DNS

website.example.ca
    → Lattice publication A

payments.example.ca
    → Lattice publication B

admin.example.ca
    → Lattice publication C
```

Everything not participating in the fabric should remain irrelevant to the access platform.

If Resource Configuration private-DNS functionality proves appropriate, Lattice itself may manage some or all of these consumer private hosted zones.

---

# 14. TLS Strategy

The target architectural objective is:

> Preserve end-to-end application identity and allow the existing application endpoint to continue owning TLS whenever practical.

For:

```text
https://website.example.ca
```

the preferred conceptual flow is:

```text
TLS ClientHello
SNI = website.example.ca
          │
          ▼
ZTNA
          │
          ▼
Lattice transport
          │
          ▼
existing ALB
          │
          ▼
ALB certificate:
website.example.ca
```

AWS supports TLS passthrough listeners for Lattice Services. Lattice uses the SNI value for service selection while leaving the encrypted payload intact.

This avoids Lattice becoming the authoritative TLS termination point.

It also keeps application certificate lifecycle with the application.

---

# 15. Important TLS/ALB Implementation Validation

There is one implementation detail that must be validated during the proof of concept rather than assumed.

AWS documents that a Lattice TLS listener forwards to a TCP target group.

AWS also documents TCP as a supported target-group protocol for ALB target types.

However, the exact combination:

```text
TLS_PASSTHROUGH listener
        │
        ▼
TCP Lattice target group
        │
        ▼
existing ALB HTTPS :443
```

should be explicitly exercised in the PoC.

This is a product integration detail, not a conceptual architectural dependency.

If that specific combination introduces undesirable restrictions, the alternatives are:

```text
Resource Configuration using domain target
```

or, if required:

```text
Lattice TLS passthrough
       │
       ▼
NLB / TCP-compatible target
       │
       ▼
existing ALB
```

The preferred implementation is whichever preserves:

```text
website.example.ca
```

and leaves application TLS termination unchanged with the fewest moving parts.

The platform abstraction should hide this implementation choice from application owners.

---

# 16. Palo Alto ZTNA Layer

Palo Alto Prisma Access ZTNA Connector represents the identity-aware user-access portion of the system.

ZTNA Connector supports private application targets defined by:

- exact FQDN
- wildcard FQDN
- IP subnet

and associates them with Connector Groups.

For this architecture, **FQDN targets should be strongly preferred.**

For example:

```text
Target:
  FQDN: website.example.ca
  Protocol: TCP
  Port: 443
  Connector Group: prod-ca-central-1
```

This means the platform does not forward all user traffic to AWS.

Only explicitly registered private applications are associated with the ZTNA Connector Group.

Palo Alto explicitly supports using different Connector Groups for different applications.

---

# 17. Connector-Side DNS

The connector must resolve the application's private FQDN.

Palo Alto requires configured DNS servers to support resolution of private application FQDNs.

Therefore the central VPC's DNS behavior is an intentional part of the access architecture.

The flow becomes:

```text
Prisma identifies:
website.example.ca
       │
       ▼
ZTNA Connector
       │
       │ resolve website.example.ca
       ▼
Route 53 Resolver
       │
       ▼
ZTNA-specific DNS view
       │
       ▼
Lattice entry path
```

This DNS view is not the organization's general DNS infrastructure.

It is better understood as the **service-discovery layer for published ZTNA applications**.

---

# 18. Palo Alto Address Abstraction

Palo Alto further isolates user-side routing from application-side addressing.

Prisma Access reserves internal application and connector address blocks for routing traffic toward ZTNA applications and Connector Groups.

Therefore the user's session does not require awareness of the application's actual RFC1918 address.

This complements Lattice particularly well:

```text
User
 │
 ▼
Prisma application identity
 │
 ▼
Connector Group
 │
 ▼
FQDN resolution
 │
 ▼
Lattice application publication
 │
 ▼
actual application
```

At no point does the enterprise architecture require a global private IP addressing plan.

---

# 19. Connector Deployment Strategy

Because connector compute cost is considered operationally insignificant in this design, connector minimization is not an architectural objective.

The platform may deploy Connector Groups broadly by:

```text
environment × region × security domain
```

For example:

```text
prod-ca-central-1
prod-us-east-1
prod-eu-west-1

nonprod-ca-central-1
nonprod-us-east-1
nonprod-eu-west-1
```

Additional Connector Groups may be created whenever a stronger isolation boundary is desirable.

Palo Alto supports multiple connectors in a Connector Group and up to four connectors per group, along with multiple application-target deployment models including single group, disaster recovery, and proximity-based routing.

The architecture therefore favors **administrative isolation over connector conservation**.

---

# 20. Regionality

Each region should be treated as its own access cell.

For example:

```text
                   GLOBAL CONTROL PLANE

                  Service Registry
                        │
           ┌────────────┼────────────┐
           │            │            │
           ▼            ▼            ▼

     ca-central-1   us-east-1    eu-west-1
     Access Cell    Access Cell  Access Cell

      Connector      Connector    Connector
          │              │            │
       Lattice         Lattice      Lattice
          │              │            │
       regional       regional     regional
       services       services     services
```

This improves:

- failure isolation
- latency
- ownership
- operational debugging
- blast-radius control
- disaster recovery

A global service registry may know all applications, but the actual application publication remains regional.

---

# 21. The Service Registry

The registry is the authoritative mapping between application intent and deployed access resources.

An illustrative record is:

```json
{
  "applicationId": "app-42193",
  "accountId": "<account-c>",
  "region": "ca-central-1",
  "environment": "prod",
  "fqdn": "website.example.ca",
  "protocol": "tcp",
  "port": 443,
  "backendType": "internal-alb",
  "backendArn": "<alb-arn>",
  "accessClass": "enterprise-private",
  "desiredState": "enabled",
  "deploymentState": "active",
  "ztnaConnectorGroup": "prod-ca-central-1",
  "latticeNetwork": "prod-access-ca-central-1"
}
```

The registry should separate:

```text
DESIRED STATE
```

from:

```text
OBSERVED STATE
```

This allows reconciliation rather than one-shot provisioning.

For example:

```text
desiredState = enabled

observed:
  latticeService = present
  latticeAssociation = present
  dns = correct
  ztnaTarget = present
  reachability = healthy
```

If any observed item differs, the controller repairs it.

---

# 22. Application Registration Event

Application teams should not directly call the central security automation.

Instead they emit a declaration.

An example event might be:

```json
{
  "source": "enterprise.application-access",
  "detail-type": "PrivateApplicationRegistrationRequested",
  "detail": {
    "accountId": "<account-c>",
    "region": "ca-central-1",
    "resourceArn": "<internal-alb-arn>",
    "fqdn": "website.example.ca",
    "port": 443,
    "environment": "prod"
  }
}
```

This event could be created in several ways:

- application deployment pipeline
- AWS Config detection
- CloudTrail event
- tag discovery
- account-local Lambda
- service catalog deployment
- explicit API call
- infrastructure pipeline
- scheduled inventory scanner

The platform should not care which mechanism originated the request.

All input is normalized into a registration event.

---

# 23. Account-Local Observer

A preferred security model is to deploy a small organization-standard component in each participating application account.

Conceptually:

```text
Account C

AWS resource event
      │
      ▼
Local EventBridge rule
      │
      ▼
Registration Publisher
      │
      ▼
Central EventBridge bus
```

The publisher has only one meaningful permission:

```text
events:PutEvents
```

against the organization's registration event bus.

It does not need permission to modify central infrastructure.

The receiving event bus uses a restrictive resource policy based on:

- organization ID
- known account IDs
- allowed event source
- allowed event types

AWS supports both account-specific and organization-scoped EventBridge event-bus policies.

---

# 24. Registration Controller

The central Registration Controller converts events into desired state.

For a new application it performs:

```text
Receive request
      │
      ▼
Authenticate source
      │
      ▼
Validate account / organization
      │
      ▼
Validate environment
      │
      ▼
Validate FQDN ownership
      │
      ▼
Validate resource type
      │
      ▼
Validate internal/private status
      │
      ▼
Validate target region
      │
      ▼
Check duplicate registration
      │
      ▼
Write desired state
      │
      ▼
Trigger provisioning workflow
```

A duplicate event should not result in duplicate infrastructure.

All provisioning must therefore be idempotent.

---

# 25. Provisioning Workflow

A Step Functions workflow is a natural orchestration mechanism, although equivalent orchestration technology could be substituted.

The conceptual state machine is:

```text
REGISTER
  │
  ▼
VALIDATE APPLICATION
  │
  ▼
DISCOVER EXISTING BACKEND
  │
  ▼
SELECT ACCESS CELL
  │
  ▼
CREATE APPLICATION-SIDE LATTICE OBJECTS
  │
  ▼
ASSOCIATE WITH PROD ACCESS
  │
  ▼
CREATE / VERIFY DNS STEERING
  │
  ▼
REGISTER FQDN IN ZTNA
  │
  ▼
APPLY ACCESS METADATA / POLICY TAGS
  │
  ▼
END-TO-END VERIFY
  │
  ▼
MARK ACTIVE
```

A failure at any step should result in either:

```text
safe partial state + reconciliation
```

or:

```text
rollback
```

depending on the resource.

---

# 26. Cross-Account Provisioning

The registry/orchestration account should not possess permanent broad administrator privileges in every workload account.

Each participating application account should receive a tightly constrained role, for example:

```text
EnterpriseAccessFabricProvisioner
```

The central orchestrator assumes this role only when required.

Its permissions may include narrowly scoped actions for:

- VPC Lattice
- target groups
- resource gateways
- service associations
- resource tags
- selected Route 53 operations, if required

Conditions should restrict actions based on:

```text
aws:PrincipalOrgID
resource tags
requested tags
region
specific service-network ARN
```

The security account should similarly expose a narrow deployment role.

The orchestrator should not receive broad interactive access to the security account.

---

# 27. Automatic Backend Discovery

Application teams should not be expected to supply implementation details that AWS already knows.

If the registered FQDN points to an internal ALB, the platform should discover:

```text
FQDN
 │
 ▼
Route 53 alias
 │
 ▼
ALB
 │
 ├── account
 ├── region
 ├── VPC
 ├── listener
 ├── TLS port
 └── resource ARN
```

The controller should verify that the declared application corresponds to the actual backend.

This avoids a request containing:

```text
website.example.ca
```

being allowed to arbitrarily publish:

```text
some-other-sensitive-load-balancer
```

The desired design principle is:

> Registration should describe application intent, while the controller derives infrastructure topology from authoritative AWS state.

---

# 28. Generated Application-Side Resources

For a traditional Lattice Service implementation, the controller may generate:

```text
Account C

Lattice Service:
  zlaf-website-example-ca

Custom domain:
  website.example.ca

Listener:
  TLS/443 or validated equivalent

Target Group:
  generated for existing internal ALB

Target:
  existing ALB

Association:
  → prod-access-ca-central-1
```

AWS requires an ALB registered as a Lattice target to be internal, and the target group must be in the same account and VPC as that ALB.

That requirement strongly supports creating application-side Lattice objects in the application's own account.

---

# 29. Generated Central-Side Resources

The central security account should not normally receive a unique network connection for every application.

Its long-lived regional structure is:

```text
ZTNA Connector
      │
      ▼
regional service-network endpoint
      │
      ▼
regional Prod Access service network
```

Adding application number 500 should ideally require no new central VPC route or VPC attachment.

Only application registration state changes.

This is one of the architecture's major scaling advantages.

---

# 30. ZTNA Registration

After the AWS path exists, the controller registers the application in Palo Alto.

Conceptually:

```text
FQDN:
website.example.ca

Protocol:
TCP

Port:
443

Connector Group:
prod-ca-central-1

Tags:
environment=prod
access-class=enterprise
application-id=app-42193
```

Palo Alto supports application tags for FQDN targets, and those tags can be used to drive dynamic address groups and policy behavior.

This is particularly valuable for automation.

Rather than generating one security rule per application, policy can consume application metadata.

For example:

```text
Applications tagged:
access-tier=standard-prod
```

could automatically participate in a predefined security-policy framework.

---

# 31. Policy Should Be Metadata-Driven

Application registration and user authorization should be distinct operations.

Publishing:

```text
website.example.ca
```

should mean:

> The application is technically reachable through the access fabric.

It should not mean:

> Every enterprise user may access it.

Authorization should remain in the ZTNA security-policy layer.

For example:

```text
Application:
website.example.ca

Application tags:
business-unit=finance
sensitivity=internal
environment=prod

Access policy:
Finance-Employees
    →
finance/internal/prod applications
```

This prevents application connectivity automation from implicitly becoming an authorization mechanism.

---

# 32. Service Management Contract

The platform should expose a very small contract to application teams.

The application owner must provide or satisfy:

```text
1. A stable FQDN.

2. A supported private backend.

3. A declared service port.

4. A supported AWS region.

5. A supported environment/security classification.

6. A declaration that enterprise ZTNA access is desired.

7. Existing application TLS appropriate for the FQDN where TLS is required.
```

Everything else belongs to the access platform.

---

# 33. What Application Teams Should NOT Have to Do

The platform should explicitly promise that application teams do not need to:

```text
request VPC peering
request Transit Gateway attachment
change VPC CIDRs
avoid overlapping RFC1918 space
create central routes
manage connector VMs
configure Palo Alto manually
create Lattice resources manually
create ZTNA DNS records manually
duplicate certificates into a central account
create NAT for central access
understand the security VPC topology
maintain central firewall objects
```

This promise is central to the value proposition.

---

# 34. Onboarding Lifecycle

The intended lifecycle should look like:

```text
Application created
       │
       ▼
Application tagged / declares access
       │
       ▼
Account-local observer detects declaration
       │
       ▼
Registration event sent
       │
       ▼
Central registry validates
       │
       ▼
Desired-state record created
       │
       ▼
Lattice publication generated
       │
       ▼
DNS access path generated
       │
       ▼
ZTNA FQDN target generated
       │
       ▼
Reachability test succeeds
       │
       ▼
Application state = ACTIVE
```

No human network ticket is required in the standard case.

---

# 35. Deregistration Lifecycle

Deregistration is just as important.

If:

```text
EnterpriseAccess = disabled
```

or the application is deleted, the system emits:

```text
PrivateApplicationDeregistrationRequested
```

The controller then:

```text
disable ZTNA target
        │
        ▼
wait for session drain if required
        │
        ▼
remove DNS steering
        │
        ▼
remove Lattice association
        │
        ▼
delete generated service/resource
        │
        ▼
delete generated target group
        │
        ▼
mark registry entry RETIRED
```

The historical registry record should remain available for audit.

---

# 36. Reconciliation

The system must not depend solely on events.

Events can be lost, delayed, duplicated, or generated in unexpected order.

A periodic reconciliation engine should compare:

```text
desired state
```

against:

```text
actual AWS + Palo Alto state
```

Examples:

```text
Registry says enabled
but Lattice service missing
→ recreate

Registry says disabled
but ZTNA target exists
→ remove

Registry says backend ALB X
but application DNS now points to ALB Y
→ flag / reconcile

Lattice association exists
but application no longer exists
→ quarantine / remove
```

This turns the platform into a controller rather than a collection of scripts.

---

# 37. Drift Detection

Drift should be explicitly classified.

Examples include:

```text
BACKEND_CHANGED
DNS_CHANGED
PORT_CHANGED
CERTIFICATE_CHANGED
ALB_DELETED
LATTICE_ASSOCIATION_REMOVED
ZTNA_TARGET_REMOVED
SERVICE_NETWORK_SHARE_REMOVED
ACCESS_POLICY_CHANGED
```

Some drift can be repaired automatically.

Some should require human review.

The policy should be encoded per drift type.

---

# 38. Event Architecture

A recommended high-level event architecture is:

```text
APPLICATION ACCOUNT
      │
      ▼
Local EventBridge
      │
      ▼
Central Registration Event Bus
      │
      ▼
Validation Rule
      │
      ▼
SQS Intake Queue
      │
      ▼
Registration Controller
      │
      ▼
DynamoDB Desired-State Registry
      │
      ▼
Provisioning Event
      │
      ▼
Step Functions
```

SQS between EventBridge and processing provides:

- buffering
- retry control
- backpressure
- dead-letter handling
- isolation from bursts

The design should assume at-least-once delivery and therefore require idempotency everywhere.

---

# 39. Event Types

The domain model should include events such as:

```text
ApplicationAccessRequested
ApplicationAccessValidated
ApplicationAccessRejected

ApplicationProvisioningStarted
ApplicationLatticeProvisioned
ApplicationDnsProvisioned
ApplicationZtnaProvisioned

ApplicationAccessActive

ApplicationUpdateRequested
ApplicationAccessRemovalRequested
ApplicationAccessRemoved

ApplicationDriftDetected
ApplicationHealthDegraded
ApplicationHealthRestored

ApplicationProvisioningFailed
```

The event vocabulary becomes the platform's internal API.

---

# 40. State Model

Each application should have a deterministic lifecycle:

```text
DISCOVERED
    │
    ▼
REQUESTED
    │
    ▼
VALIDATING
    │
 ┌──┴───┐
 │      │
 ▼      ▼
REJECTED PROVISIONING
           │
           ▼
        VERIFYING
           │
      ┌────┴────┐
      │         │
      ▼         ▼
    ACTIVE     FAILED
      │
      ▼
 DECOMMISSIONING
      │
      ▼
    RETIRED
```

A human operator should be able to look at one registry entry and immediately know where an application is in this lifecycle.

---

# 41. Failure Isolation

A failure onboarding one application must not affect another application.

This means the unit of change should be:

```text
application publication
```

not:

```text
entire regional service network
```

A malformed `website.example.ca` registration should not cause a deployment replacement of `Prod Access`.

Long-lived foundational infrastructure and application-specific ephemeral configuration should be clearly separated.

---

# 42. Security Boundaries

The architecture should maintain at least these distinct boundaries:

```text
USER IDENTITY
      │
      ▼
Prisma authorization

APPLICATION REGISTRATION
      │
      ▼
Registry validation

AWS CONNECTIVITY
      │
      ▼
Lattice association

DNS DISCOVERY
      │
      ▼
controlled Route 53 view

APPLICATION IDENTITY
      │
      ▼
TLS / existing application certificate

BACKEND ACCEPTANCE
      │
      ▼
ALB / backend security controls
```

Compromise of one layer should not automatically remove every other layer.

---

# 43. Lattice Is Not the User Authorization Layer

In the TLS-pass-through model, Lattice should primarily be treated as a private application transport mechanism.

AWS notes that Lattice auth policies are limited when using TLS passthrough because Lattice cannot inspect the encrypted application request; TLS listeners are restricted to anonymous principals for auth-policy purposes.

This is acceptable because:

```text
Prisma Access
```

is the intended end-user identity and authorization layer.

Lattice's job is connectivity and service isolation.

---

# 44. Security Group Model

The application-side generated security posture should permit only the traffic needed by the Lattice path.

Security controls should be generated from service metadata rather than broad network ranges.

For example:

```text
Application publication:
TCP/443

Generated backend allowance:
Lattice path → ALB :443
```

No rule should say:

```text
Central VPC 10.x.x.x → entire application VPC
```

because the architecture is specifically designed to avoid that trust model.

---

# 45. Overlapping CIDRs

Overlapping address space is an expected condition, not an exception.

Example:

```text
Account A / VPC A
10.0.0.0/16

Account B / VPC B
10.0.0.0/16

Account C / VPC C
10.0.0.0/16
```

The access fabric distinguishes:

```text
website-a.example.ca
website-b.example.ca
website-c.example.ca
```

rather than trying to distinguish:

```text
10.0.1.10
10.0.1.10
10.0.1.10
```

AWS explicitly states that VPC Lattice supports overlapping CIDR technology.

This property is fundamental to the design.

---

# 46. No Transitive Mesh

The term “mesh” should be used carefully.

This is not:

```text
Account A ↔ Account B ↔ Account C ↔ Security
```

It is:

```text
             ACCESS FABRIC
            /      |      \
           /       |       \
          ▼        ▼        ▼
     Service A Service B Service C
```

Application VPCs remain mutually unrouted unless they have some unrelated networking requirement.

The access architecture therefore does not accidentally create east-west application connectivity.

---

# 47. Service-Network Segmentation

A single `Prod Access` network is conceptually simple, but multiple service networks may eventually be appropriate for stronger isolation.

Examples:

```text
prod-standard
prod-restricted
prod-regulated
nonprod
```

This should be driven by genuine security boundaries, not organizational sprawl.

The architecture should avoid creating one service network per account or per application unless there is a specific security reason.

---

# 48. Multi-Region Application Behavior

A multi-region application may register:

```text
website.example.ca
```

in multiple regions.

The registry can represent those as multiple regional publications belonging to one logical application.

For example:

```text
Logical application:
website.example.ca

Regional publications:
├── ca-central-1
├── us-east-1
└── eu-west-1
```

Palo Alto supports assigning FQDN targets to Connector Groups in different compute locations for proximity-based routing, as well as primary/standby configurations for disaster recovery.

This provides a natural future path for geographic routing.

---

# 49. Observability

The access platform should produce correlated telemetry across:

```text
Prisma
Route 53
ZTNA Connector
Lattice
ALB
Application
Registry
Provisioning workflow
```

VPC Lattice provides access logging and CloudWatch metrics for traffic traversing services and service networks.

Each registry entry should contain identifiers enabling telemetry correlation:

```text
application ID
account ID
region
FQDN
Lattice service ID
service-network ID
target-group ID
backend ARN
connector group
```

---

# 50. Operational Dashboard

An operator should see something similar to:

```text
Application                 State     Region         Backend    ZTNA      Lattice
--------------------------------------------------------------------------------
website.example.ca          ACTIVE    ca-central-1   ALB        Healthy   Healthy
payments.example.ca         ACTIVE    us-east-1      ALB        Healthy   Healthy
admin.example.ca            DEGRADED  ca-central-1   ALB        Healthy   Failed
reports.example.ca          FAILED    eu-west-1      ALB        Missing   N/A
```

The operator should not need to inspect five AWS consoles and Prisma manually to understand application state.

---

# 51. End-to-End Synthetic Verification

Provisioning should not be considered complete merely because AWS API calls succeeded.

The controller should verify:

```text
DNS lookup
      │
      ▼
expected Lattice resolution
      │
      ▼
TCP connection
      │
      ▼
TLS handshake
      │
      ▼
certificate identity
      │
      ▼
application response
```

A registration should become `ACTIVE` only after this check succeeds.

---

# 52. TLS Validation as a Safety Mechanism

Because the final application continues presenting the certificate for:

```text
website.example.ca
```

TLS provides an important correctness check.

If DNS accidentally routes the application to an unrelated backend, that backend should not normally possess a valid certificate for:

```text
website.example.ca
```

Therefore:

```text
DNS tells the client where to go.
TLS confirms what application it reached.
```

This separation is desirable.

---

# 53. DNS Security

DNS for connector VPCs should be intentionally constrained.

The ZTNA Connector should use the expected Route 53 resolver path.

Resolver query logging should be enabled.

Where appropriate, Route 53 Resolver DNS Firewall can be introduced to constrain domains that the connector may resolve.

However, care must be taken because Palo Alto ZTNA Connector itself requires public DNS access to specific Palo Alto service endpoints to establish and maintain its control plane. Palo Alto publishes required public FQDNs for connector operation.

Therefore an allowlist must include both:

```text
registered private applications
```

and:

```text
required connector control-plane destinations
```

---

# 54. Secrets and Connector Activation

If connector compute is maintained with an on-demand or scale-from-zero model, the connector lifecycle is separate from application registration.

A potential sequence is:

```text
Palo Alto connector credentials available
       │
       ▼
Secrets Manager
       │
       ▼
activation event
       │
       ▼
regional connector ASG desired capacity > 0
       │
       ▼
connector boots
       │
       ▼
connector registers with Prisma
```

This does not need to be entangled with Lattice application publishing.

The regional access cell should remain logically valid even while its connector compute is dormant.

---

# 55. Central Monitoring Account

The central registry account also acts as the monitoring and coordination plane.

It receives events from:

```text
Application accounts
Security account
AWS Config
CloudTrail
Lattice
Provisioning workflows
Health checks
Palo Alto integration
```

It should publish higher-order events such as:

```text
ApplicationAccessActive
```

rather than forcing every downstream consumer to interpret raw AWS events.

That makes the platform extensible.

---

# 56. Notification Model

Human notification should be generated only where useful.

Example:

```text
New application declaration detected
        │
        ▼
automatic validation
        │
    ┌───┴────┐
    │        │
    ▼        ▼
 valid     invalid
    │        │
    ▼        ▼
provision   notify owner
```

Routine successful provisioning should not create operational tickets.

Failures, policy violations, and unresolved drift should.

---

# 57. Registration API

Even if the primary source is EventBridge, the registry should expose a stable conceptual API.

For example:

```text
RegisterApplication
UpdateApplication
DeregisterApplication
GetApplication
ListApplications
ReconcileApplication
```

Events and automation should ultimately call the same domain service.

This prevents the implementation becoming dependent on one AWS event source.

---

# 58. Application Metadata

The minimum application metadata should likely include:

```yaml
applicationId: payments-prod
fqdn: payments.example.ca
environment: prod
region: ca-central-1
port: 443
protocol: tcp
backend:
  type: alb
  arn: optional-if-discoverable
access:
  class: enterprise-private
  enabled: true
owner:
  team: payments-platform
```

Additional metadata can drive policy without changing the networking model.

---

# 59. Naming

Generated AWS objects should have deterministic names.

For example:

```text
zlaf-prod-ca-website-example-ca
```

A deterministic naming function should use:

```text
environment
region
application ID
```

and maintain the FQDN in tags even if AWS naming constraints prevent using it directly.

---

# 60. Resource Tags

Every generated object should contain a standard tag set such as:

```text
ManagedBy           = ZLAF
ApplicationId       = app-42193
ApplicationFQDN     = website.example.ca
Environment         = prod
OwnerAccount        = <account-c>
RegistryRecord      = <record-id>
ProvisioningVersion = 3
```

These tags support:

- IAM conditions
- lifecycle management
- cost allocation
- drift detection
- inventory
- emergency cleanup

---

# 61. Idempotency

Every workflow operation must be safely repeatable.

For example:

```text
CreatePublication(app-42193)
```

called ten times should still produce one publication.

Event IDs, application IDs, deterministic resource names, and registry conditional writes should enforce this.

This is necessary because an event-driven architecture cannot rely on exactly-once delivery.

---

# 62. Deletion Protection

Critical shared infrastructure such as:

```text
Prod Access service network
service-network endpoint
regional access VPC
registry
```

should have stronger deletion protections than application-level generated resources.

Application publications should be replaceable.

The service network should be foundational infrastructure.

---

# 63. Emergency Revocation

The architecture should support rapid revocation at several levels.

For example:

```text
USER
→ deny in Prisma

APPLICATION
→ disable ZTNA target

REGIONAL APPLICATION
→ remove Lattice association

APPLICATION ACCOUNT
→ revoke RAM / policy participation

SERVICE NETWORK
→ emergency deny

REGION
→ disable connector group
```

This gives operators different blast-radius options during incidents.

---

# 64. Failure Modes

Major anticipated failure modes include:

```text
Connector unavailable
Lattice endpoint unavailable
Lattice publication missing
Lattice association removed
backend ALB unavailable
DNS mapping incorrect
TLS certificate invalid
registration workflow failure
Palo Alto API unavailable
cross-account role denied
RAM share removed
AWS regional impairment
```

Each must have:

```text
detector
state transition
retry policy
alerting threshold
recovery procedure
```

---

# 65. What This Architecture Does Not Solve

The platform is not intended to provide general-purpose private routing.

It does not mean:

```text
users can reach anything in 10.0.0.0/8
```

It means:

```text
authorized users can reach published applications.
```

The distinction is intentional.

Legacy arbitrary-IP access, SSH fleets, RDP, network appliances, or unsupported protocols may require a different access pattern or a compatible Lattice Resource Configuration.

---

# 66. Architectural Advantages

The architecture provides the following strategic properties.

**No global CIDR management requirement.** Overlapping application VPCs are viable.

**No central private WAN requirement.** VPCs need not join a transitive network.

**Application identity is stable.** `website.example.ca` remains `website.example.ca`.

**Existing private ALBs remain private.**

**Application TLS can remain application-owned.**

**Application onboarding becomes declarative.**

**Regional isolation is natural.**

**Account-level isolation is preserved.**

**Network engineering is removed from the normal application onboarding path.**

**Application access is individually publishable and revocable.**

**The architecture is compatible with automated ZTNA policy.**

---

# 67. Principal Tradeoffs

The design does introduce several deliberate platform responsibilities.

The platform must operate:

```text
a service registry
an event-driven provisioning controller
ZTNA DNS steering
cross-account roles
Lattice service lifecycle
application verification
reconciliation
```

These are software-platform responsibilities rather than traditional network-engineering responsibilities.

That trade is intentional.

The desired outcome is to replace repeated human network configuration with deterministic software.

---

# 68. Proof-of-Concept Architecture

The first PoC should use:

```text
Central Security Account
    │
    ├── one region
    ├── one access VPC
    ├── one open-source ZTNA substitute
    ├── one service-network endpoint
    └── one Prod Access service network

Account C
    │
    ├── VPC
    ├── internal ALB
    └── website.example.ca

Account D
    │
    ├── overlapping VPC CIDR
    ├── internal ALB
    └── payments.example.ca

Registry Account
    │
    ├── EventBridge
    ├── SQS
    ├── Lambda / Step Functions
    └── DynamoDB
```

NetBird can temporarily substitute for the Palo Alto client/connector layer during this architecture PoC.

The objective is not to test NetBird as a production product.

The objective is to verify everything below the ZTNA abstraction.

---

# 69. PoC Success Criteria

The PoC should prove all of the following:

```text
1. User accesses website.example.ca without hostname modification.

2. ZTNA selects only the registered FQDN.

3. Connector-side DNS steers that FQDN into Lattice.

4. Lattice reaches Account C without routed VPC connectivity.

5. Existing internal ALB remains private.

6. Existing application TLS identity remains valid.

7. Account D can use overlapping RFC1918 space.

8. Registering a second application requires no central route change.

9. Application registration can be triggered by an event.

10. Application deregistration removes access automatically.

11. Reconciliation repairs intentionally deleted generated resources.

12. The application developer performs no Lattice or ZTNA configuration.
```

---

# 70. Implementation Phases

## Phase 1 — Connectivity Proof

Manually build:

```text
ZTNA substitute
→ central VPC
→ Lattice
→ Account C
→ existing ALB
```

Prove FQDN and TLS behavior.

This phase should explicitly validate the TLS-passthrough-to-existing-ALB implementation choice.

---

## Phase 2 — Overlapping CIDR Proof

Add Account D using overlapping RFC1918 space.

Publish a second application.

Confirm neither central routing nor CIDR translation is required.

---

## Phase 3 — Registration Controller

Introduce:

```text
EventBridge
SQS
registry
Step Functions
cross-account deployment roles
```

Make publication fully automatic.

---

## Phase 4 — ZTNA Integration

Replace the open-source ZTNA substitute with Palo Alto Prisma Access.

Automate:

```text
FQDN targets
Connector Group selection
application tags
policy integration
```

---

## Phase 5 — Production Hardening

Add:

```text
multi-region cells
reconciliation
drift detection
synthetic monitoring
audit
dead-letter handling
security controls
SCP integration
quotas
capacity monitoring
regional DR
```

---

# 71. Design Decision: Service vs Resource Configuration

One of the principal decisions the PoC must resolve is:

```text
Lattice Service + target group
```

versus:

```text
Lattice Resource Configuration
```

The decision should be driven by the ability to provide:

```text
same FQDN
existing application TLS
minimal DNS administration
minimal application modification
clean automation
```

The service registry should hide this decision behind an `ApplicationPublication` abstraction so the implementation can evolve without changing the application-team contract.

---

# 72. Design Decision: DNS Ownership

A second important decision is whether the platform:

```text
generates narrow Route 53 private DNS overrides
```

or relies where practical on:

```text
VPC Lattice private-DNS management for Resource Configurations.
```

Either model is acceptable if the outcome remains:

```text
website.example.ca
```

for users and developers.

DNS implementation is a platform implementation detail and should not leak into the application contract.

---

# 73. Design Decision: Registration Signal

Applications may be registered by:

```text
tag
deployment annotation
Service Catalog setting
pipeline declaration
central API request
```

The architecture should normalize all of these into the same registry event.

The platform therefore remains independent of a specific application deployment technology.

---

# 74. Governance

The central service registry should become the authoritative enterprise inventory of private applications exposed through ZTNA.

It should answer questions such as:

```text
Which applications are exposed?

Which accounts own them?

Which FQDNs are registered?

Which regions provide them?

Which Connector Groups serve them?

What backend resource is used?

Who owns the service?

What access classification applies?

When was it last validated?

Is the end-to-end path healthy?
```

This creates value beyond networking.

---

# 75. Desired Developer Experience

The ideal developer experience is:

```text
Developer creates application.

Developer creates:
website.example.ca

Developer marks:
private enterprise access = enabled.

Developer does nothing else.
```

A short period later:

```text
website.example.ca
```

is available to authorized remote users through ZTNA.

The developer does not know or care whether the implementation involved:

```text
Lattice Service
Resource Configuration
DNS override
regional connector group
service-network association
```

That complexity belongs to the platform.

---

# 76. Desired Security-Team Experience

The security team should not maintain per-application routes.

Instead it manages policy abstractions:

```text
Application classification
User classification
Environment
Sensitivity
Access policy
```

For example:

```text
Engineering users
     │
     ▼
applications tagged:
team-access=engineering

Finance users
     │
     ▼
applications tagged:
team-access=finance
```

The individual FQDN inventory is generated by the registry and ZTNA integration.

---

# 77. Desired Network-Team Experience

The network team manages the regional access cells:

```text
Access VPC
Lattice endpoint
service network
DNS resolver architecture
regional capacity
```

It does not onboard individual application routes.

Application number 1 and application number 10,000 should look approximately the same from the central VPC perspective.

That is a principal success metric.

---

# 78. Long-Term Strategic Outcome

The end-state is not simply:

> Palo Alto connected to AWS.

It is an enterprise **private application publishing platform**.

The platform creates a standardized path:

```text
application intent
       │
       ▼
service registry
       │
       ▼
policy validation
       │
       ▼
application publication
       │
       ▼
private service fabric
       │
       ▼
identity-aware access
```

Networking becomes a generated implementation detail.

---

# 79. Final Architecture Statement

The Zero-Trust Lattice Access Fabric should be defined as:

> A regional, identity-aware private application access architecture that uses Palo Alto Prisma Access ZTNA Connector as the enterprise user-access plane, Amazon VPC Lattice as the cross-account service-connectivity plane, Route 53 as the application service-discovery plane, and an event-driven central registry as the lifecycle and orchestration plane.

Its fundamental properties are:

```text
No centralized routed private network required.

No dependence on globally unique application VPC CIDRs.

No requirement to rename applications.

No routine application-developer networking work.

No manual per-application ZTNA provisioning.

No application exposure simply because an account participates.

Applications explicitly publish into the fabric.

Users explicitly receive authorization through ZTNA.

TLS identity remains associated with the real application.

Application accounts retain their own infrastructure boundaries.

A central registry controls and reconciles desired state.

Everything repeatable is automated.
```

The resulting architecture should feel less like connecting networks and more like registering services in an enterprise private-access directory.

That is the target vision.

---

# 80. Architecture in One Sentence

**An application declares its existing FQDN, the platform automatically publishes that application into a regional VPC Lattice service fabric, creates the ZTNA and DNS representation required to reach it, and Prisma Access provides authorized users access to the original application without making the application's VPC part of a centralized private network.**
