# Options for expanding an Azure API Management subnet

Date: September 23, 2026

Scope: classic APIM, Developer or Premium, with VNet injection.

Status: planning alternatives. Option 2 was verified in the Developer lab; options 1 and 3 have not been executed in this project.

## Summary and recommendation

**Recommendation:** create a larger subnet and move the existing APIM instance to it when retaining the original address block is not required.

| Option | When to choose it | Main benefit | Main cost or risk |
|---|---|---|---|
| 1. New larger subnet | You can change the address block | One subnet change, preserving the APIM instance | Potential IP changes and connectivity adjustments |
| 2. Temporary subnet and return | You need to expand the original subnet | Retains the original subnet as the final destination | Two network changes and longer duration |
| 3. Second APIM instance | You need parallel validation and control over switching back | Preserves the old environment during transition | Duplicate costs and configuration migration |

## PoC evidence

The classic Developer External lab in East US 2 attempted to expand an occupied subnet from `10.90.0.0/27` to `10.90.0.0/26`. Azure rejected the single attempt with:

```text
Code: InUsePrefixCannotBeDeleted
Message: IpPrefix 10.90.0.0/27 on Subnet snet-apim-original has active allocations and cannot be deleted.
```

After that attempt, the subnet remained /27 and APIM remained `Succeeded`, attached to the same subnet. HTTP checks before and after returned 200; they do not prove continuous availability.

See the [full direct-attempt record and evidence](.azure/deployment-plan.md#8-deployment-and-experiment-result). The subsequent option 2 migration completed successfully; see the [migration report](APIM-SUBNET-MIGRATION-RESULTS.md). Developer observations do not establish Premium behavior or availability.

## Option 1. Create a larger subnet and move the existing APIM instance

Example: move the same APIM instance from `10.90.0.0/27` to a new subnet `10.90.1.0/26`, provided the block is free and contained within the VNet address space.

### Procedure

1. Reserve a non-overlapping block large enough for the expected capacity.
2. Create the subnet in the same region and subscription as APIM, preferably in the current VNet.
3. Configure NSG, routes, DNS resolution and access to backends and dependencies.
4. Update APIM's network configuration to select the new subnet while retaining External mode.
5. Wait for completion and validate provisioning state, gateway, backends, DNS and access rules.
6. Retain the old subnet during the validation window. Consider deletion only with approval.

### Benefits and precautions

- Preserves the instance, APIs, policies and other configuration.
- Requires one subnet change.
- Public and private IPs may change. Review allowlists, firewalls and DNS records pointing directly to IP addresses.
- Returning to the previous subnet requires another network operation and does not guarantee restoration of old IPs.

## Option 2. Move temporarily, expand the original subnet and return

Choose this option when the original subnet must remain the final destination.

### Procedure

1. Create a temporary subnet with sufficient capacity, such as `10.90.1.0/27` for this lab, if available.
2. Prepare its connectivity and move APIM to it.
3. Wait for completion and confirm that all allocations on the original subnet have been released, including APIM-managed allocations.
4. Confirm that the original subnet contains no other resources and that the additional range `10.90.0.32` through `10.90.0.63` is available.
5. Expand the original subnet from `10.90.0.0/27` to `10.90.0.0/26`.
6. Move APIM back and validate the service and its dependencies.
7. Consider deleting the temporary subnet only after validation and approval.

### Benefits and precautions

- Allows expansion of the original subnet once it is empty.
- Requires two network changes, increasing duration and potentially changing IPs on both moves.
- The temporary subnet must be outside the final /26 block to avoid overlap.
- Do not manually remove APIM-managed internal resources to force subnet release.
- Returning to the original subnet does not guarantee restoration of previous IPs.

## Option 3. Create another APIM instance and perform a controlled cutover

Choose this option when you need to test the new environment in parallel and retain the old environment as a fallback.

### Procedure

1. Deploy another APIM instance in a larger subnet.
2. Reproduce APIs, policies, products, named values, backends and required configuration.
3. Plan subscriptions and keys, certificates, domains, identities, permissions and Key Vault references. Do not assume that exporting APIs transfers all configuration.
4. Validate authentication, connectivity, API behavior, load and observability.
5. Route traffic through a custom domain or ingress layer, with checks and criteria for switching back.
6. Retain the old instance for the agreed window. Delete it only after approval.

### Benefits and precautions

- Allows destination validation before it receives primary traffic.
- Retains the old environment as a fallback, provided its configuration remains consistent.
- Temporarily incurs the cost of two instances.
- The old instance's default hostname does not transfer automatically.
- Cutover requires planning for DNS, certificates, caches, existing connections and credentials. It does not guarantee zero interruption.

## Sizing and shared checks

| Prefix | Total addresses | Usable after Azure's five reservations |
|---|---:|---:|
| /27 | 32 | 27 |
| /26 | 64 | 59 |
| /25 | 128 | 123 |
| /24 | 256 | 251 |

- Usable addresses are not necessarily free addresses.
- For classic Premium, account for two IPs per unit; for Developer, one IP per instance. Internal mode requires an additional IP for the internal load balancer.
- Size for expected maximum capacity, growth and infrastructure operation requirements rather than current consumption alone.
- Expanding only the VNet address space does not expand an existing subnet. It can provide room for a new subnet.
- For classic APIM, the subnet must have no delegation and must have an NSG with APIM's required rules.
- Check NSG, UDR, firewall, DNS, peering and backend access before each change.
- Infrastructure updates may take 15 minutes or longer. Do not start concurrent changes.
- Developer may experience downtime. Premium's rolling updates do not eliminate connectivity risks caused by IPs, DNS, routes or firewalls.
- Reassess specific requirements for Premium v2 or other connectivity models; this document covers classic APIM.

## Automation and observed result

The [option 2 script](scripts/Invoke-SubnetMigration.ps1) implements temporary-subnet migration **only for the classic Developer External lab**, with confirmation, `-WhatIf`, allocation-release polling, mock validation and evidence. See [execution and recovery](README.md#4-option-2-expand-using-a-temporary-subnet). It retains the temporary subnet and stops on failure without automatic rollback or retry.

Option 2 completed on September 23, 2026, with outcome `Verified` in **1 hour, 12 minutes and 49 seconds**. APIM returned to the original /26 subnet with state `Succeeded` and a successful final HTTP check. This duration does not measure API downtime. See the [detailed results](APIM-SUBNET-MIGRATION-RESULTS.md).

The direct experiment remains separate. Options 1 and 3 have no automation in this project. Additional tests, migrations or cleanup require separate approval. Lab resources were retained at completion and incur costs until deleted.

## References

- [Changing a subnet range requires moving resources](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-manage-subnet#change-subnet-settings).
- [Configure classic APIM in an External VNet](https://learn.microsoft.com/en-us/azure/api-management/api-management-using-with-vnet).
- [Network requirements and subnet sizing](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-injection-resources#subnet-size).
- [APIM IP address changes](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-ip-addresses#changes-to-ip-addresses).
