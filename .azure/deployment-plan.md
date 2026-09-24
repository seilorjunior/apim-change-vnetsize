# APIM occupied-subnet resize deployment

## 1. Status

Deployment completed; single occupied-subnet expansion attempt completed and
rejected by Azure. Pre-deployment validation passed. This document records the
initial deployment and direct experiment, which performed no migration or
automatic cleanup. The separately authorized, subsequent option 2 migration
is documented in the [migration results](../APIM-SUBNET-MIGRATION-RESULTS.md).

## 2. Azure context

- Subscription name and ID: local `.env`, `AZURE_SUBSCRIPTION_NAME` and `AZURE_SUBSCRIPTION_ID`.
- Tenant: local `.env`, `AZURE_TENANT_ID`.
- Region: `eastus2`.
- Resource group created for this run: local `.env`, `AZURE_RESOURCE_GROUP`.
- Publisher email: local `.env`, `APIM_PUBLISHER_EMAIL`.
- APIM name: local `.env`, `APIM_NAME`; deterministic `apim-resize-poc-` name from the existing template.
- Resource group absence and APIM/Network provider registration verified.

## 3. Recipe and infrastructure

Recipe type: `bicep`, resource-group scope, Azure CLI, incremental deployment.
Reuse [main.bicep](../infra/main.bicep) without architecture changes.
Existing direct resource modules preserve the approved minimal lab topology.

- APIM Developer classic, External VNet injection, capacity 1.
- VNet `10.90.0.0/16`; only subnet `snet-apim-original`, initially `10.90.0.0/27`.
- Lab NSG and public, non-sensitive mock `GET /subnet-poc/health`.
- Tags: `purpose=apim-subnet-resize-poc`, `environment=lab`.
- No production resources, peering, migration subnet, or APIM relocation.

## 4. Execution

1. Compile Bicep and run offline tests.
2. Create the approved empty resource group for group-scoped ARM validation.
3. Validate and inspect what-if; stop on unintended changes or validation errors.
4. Deploy once, wait for completion, inspect outputs and resource states.
5. Verify exact mock response and original /27 association.
6. Execute `TryResizeOccupied` once, recording response and before/after state.
7. Verify gateway separately and retain evidence under `artifacts`.

## 5. Cost and lifecycle

APIM Developer incurs charges until deleted; no SLA. User approved ongoing lab
cost and no automatic deletion. Developer findings do not establish Premium
availability, timing, capacity, or supportability.
Do not redeploy the initial /27 template after a successful resize.

## 6. Preflight limitations

The CLI quota command failed while loading a pre-existing azure-devops extension
with Windows access denied. No permissions or existing extensions were changed.
Use service limits, inventory, network usage and ARM validation for further
capacity evidence; none guarantees regional allocation before provisioning.
Subscription policy assignments were retrieved; ARM validation must enforce
applicable constraints.

## 7. Validation Proof

- [x] Bicep compilation: standalone `bicep build .\infra\main.bicep --outfile
  .\artifacts\deployment-eastus2\main.json`, passed, 2026-09-23T14:25:28Z.
- [x] Offline safety/HTTP tests: `pwsh -NoProfile -File .\tests\Test-Local.ps1`,
  65 assertions passed; Azure mocked.
- [x] Region-format regression fix: same command passed 71 assertions at
  2026-09-23T16:15:43Z. Editor diagnostics clean. The captured live Azure baseline
  also passed the corrected guard (read-only).
- [x] Authentication: `az account show --subscription` with the confirmed ID.
- [x] ARM template validation: `az deployment group validate`, using compiled
  template, explicit subscription, approved group, region and publisher email;
  passed at 2026-09-23T14:27:17Z. The gateway nested deployment was skipped by
  this validation because its subnet input uses a module reference.
- [x] What-if: `az deployment group what-if --no-pretty-print` with identical
  parameters, Succeeded at 2026-09-23T14:30:47Z, no diagnostics. All six expected
  resources (including APIM, API, operation and policy) were expanded as Create;
  no Modify or Delete. This supplements the nested validation limitation.
- [x] Policy preflight: subscription/inherited assignments retrieved, ARM
  validation and full what-if returned no policy denial. This is not a compliance
  certification or a guarantee against runtime provider errors.
- [x] Static role review: no application identity, external backend or role
  assignment in this mock-only template; application data-plane RBAC not needed.
- [x] Editor diagnostics: all three Bicep files have no errors.
- Network capacity: 3/1000 VNets and 5/5000 NSGs in East US 2.
- Existing APIM inventory: 8 instances, including 2 Developer.
- Published APIM limits reviewed; the one-operation mock is below documented
  resource limits. APIM regional allocation remains subject to provisioning.
- Template SHA256:
  `09EA0D34418D46C00BF416C98E5D5EBE15A09FD6DB5F5F0A359306A4E8E56F8F`.
- Evidence: [deployment files](../artifacts/deployment-eastus2/).

## 8. Deployment and experiment result

Deployment submitted at 2026-09-23T14:33:29Z with `az deployment group create`,
incremental mode and the validated compiled template. Deployment
`apim-resize-poc` succeeded; APIM (local `.env`, `APIM_NAME`) reached Succeeded,
Developer/External, platform stv2, attached to the original subnet.

Correlation ID: local `.env`, `LAB_DEPLOYMENT_CORRELATION_ID`.

The initial workflow stopped at baseline verification at 2026-09-23T14:59:01Z:
APIM returned `East US 2`, while Network returned `eastus2`. This was a local
comparison bug, not a deployment failure or an Azure resize rejection. No subnet
mutation had occurred. The guard now accepts equivalent region representations
while rejecting absent or different regions, with regression tests.
Original stopped-run evidence is preserved in
[execution.json](../artifacts/deployment-eastus2/execution.json).

After the fix, a fresh baseline passed; no redeployment was performed. Exactly
one `az network vnet subnet update --address-prefixes 10.90.0.0/26` was attempted
with explicit subscription and resource group at 2026-09-23T16:32:53Z. Azure
returned exit code 1 and:

```text
Code: InUsePrefixCannotBeDeleted
Message: IpPrefix 10.90.0.0/27 on Subnet snet-apim-original has active allocations and cannot be deleted.
```

The attempt finished at 2026-09-23T16:33:08Z with `FailedOrRejected`.
This is an explicit active-allocation rejection, not an authentication, policy
or local-validation error.

| Check | Before | After rejection |
|---|---|---|
| Subnet prefix | `10.90.0.0/27` | `10.90.0.0/27` |
| APIM provisioning state | `Succeeded` | `Succeeded` |
| Subnet provisioning state | `Succeeded` | `Succeeded` |
| APIM association | `snet-apim-original` | Same subnet resource ID |
| Gateway mock | HTTP 200, exact JSON | HTTP 200, exact JSON |

HTTP checks were captured at 16:31:01Z and 16:33:31Z. These are point-in-time
checks only; no continuous availability or absence of interruption is claimed.
Endpoint: `https://<APIM_NAME>.azure-api.net/subnet-poc/health`, with the instance
name retained in local `.env`. The original URL remains in the private evidence.

Evidence:
- [Actual Azure error and attempt timestamps](../artifacts/20260923T163253717Z-TryResizeOccupied-6f22e83e04af4ca1be16eb2c2633bcea/result.json).
- [Before state](../artifacts/20260923T163253717Z-TryResizeOccupied-6f22e83e04af4ca1be16eb2c2633bcea/before.json).
- [State after rejection](../artifacts/20260923T163253717Z-TryResizeOccupied-6f22e83e04af4ca1be16eb2c2633bcea/after-error.json).
- [HTTP before](../artifacts/deployment-eastus2/http-before-resize.json) and
  [HTTP after](../artifacts/deployment-eastus2/http-after-resize.json).
- [Final resource inventory](../artifacts/deployment-eastus2/resources-after.json).

Conclusion: Azure did not permit this direct occupied /27-to-/26 expansion in
the tested Developer classic External lab. This direct experiment performed no
retry, migration, APIM disconnection, shrinking or cleanup. Resources were
retained at its completion. Findings do not establish Premium behavior or
availability. See the separate migration report for the subsequent /26 result.

Execution evidence under `artifacts` is excluded from Git; the links above
require the local files and are not available in a fresh clone.
