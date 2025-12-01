# Zero-Trust Lattice Access Fabric — Access Cell

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Proves the central access cell for the ZLAF PoC: an access VPC with a ServiceNetwork-type VPC endpoint, a share-enabled VPC Lattice service network distributed to two application accounts via RAM, and a NetBird routing peer that uses the VPC resolver for DNS without providing a direct routed path to the application VPCs.

## Topology

One region, four accounts. The access account owns the VPC, service network, and routing peer. Application accounts C and D hold existing internal ALBs with identical VPC CIDRs (`10.0.0.0/16`), proving CIDR overlap is not a constraint.

| Constant             | Value                                    |
| -------------------- | ---------------------------------------- |
| Region               | `ca-central-1`                           |
| Access VPC CIDR      | `100.64.0.0/16` (CGNAT, non-overlapping) |
| Service network name | `zlaf-prod-access`                       |
| NetBird version      | `0.31.0`                                 |
| AWS CLI minimum      | `2.15.0`                                 |

Fill in `lab.json` with real account IDs and ALB names before running.

## Notes

- A simple idea experiment, mostly abandoned.
