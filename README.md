# PoC: expand an Azure API Management subnet

An isolated lab using **Bicep and PowerShell 7**, with two separate procedures:

1. **Direct experiment:** attempt to expand the occupied subnet from /27 to /26 while keeping APIM attached, and record Azure's response.
2. **Option 2:** move APIM to a temporary subnet, expand the empty original subnet, and move APIM back. The lab migration completed successfully on September 23, 2026, in **1 hour, 12 minutes and 49 seconds**. See the [migration results](APIM-SUBNET-MIGRATION-RESULTS.md).

The direct experiment does not move APIM or create a temporary subnet. If Azure rejects the change, it stops and records the error. Option 2 requires a separate invocation and confirmation. Neither procedure performs automatic fallback or rollback.

The reference environment is **classic Premium / External**, but this PoC uses **Developer / External**, one unit and one region to reduce cost. **It does not demonstrate Premium SLA, availability or capacity.** Developer may be unavailable during updates. APIM infrastructure changes can take 15 minutes or longer.

## Documentation language

**English is the default language for all repository documentation**, including Markdown files, headings, tables, example comments and explanatory messages in documentation examples. Preserve script parameters, recorded outcomes and evidence paths; keep real environment identifiers in local configuration rather than published examples.

Use English document filenames and update internal links when renaming documents. Contributor and agent guidance is available in [AGENTS.md](AGENTS.md).

## Known constraints and measurements

The [subnet documentation](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-manage-subnet#change-subnet-settings) instructs users to move or remove resources before changing a subnet's address range. This project therefore **does not assume that expanding an occupied subnet is supported**. The test records Azure's actual response. An RBAC, Azure Policy or transient failure does not establish a subnet restriction.

Expanding the subnet means decreasing the prefix length: **/27 to /26**, from 32 to 64 total addresses, or from 27 to 59 usable addresses after Azure's five reservations. This does not mean 59 free addresses: APIM also consumes IPs. This lab does not require a larger VNet.

| Resource | Configuration |
|---|---|
| Resource group | New group with prefix `rg-apim-resize-poc` and tag `purpose=apim-subnet-resize-poc` |
| VNet | `vnet-apim-resize-poc`, `10.90.0.0/16`, no peering |
| Original subnet | `snet-apim-original`, `10.90.0.0/27` expanded to `10.90.0.0/26` |
| NSG | Public HTTPS 443, management 3443 through ApiManagement, probe 6390 through AzureLoadBalancer |
| APIM | Globally unique name with prefix `apim-resize-poc-`, Developer, External |
| Mock API | `GET /subnet-poc/health`, HTTP 200 and `{"status":"ok","poc":"apim-subnet-resize"}` |

The Bicep template creates one subnet with no delegation, associated with the NSG. Both /27 and /26 fit within the /16 VNet. APIM and the network share a subscription and region. APIM manages its public IP; the template does not create a separate public IP resource. Only the option 2 script creates `snet-apim-temporary`, `10.90.1.0/27`, outside the original /26 block.

The mock API is public, requires no subscription key, exposes no real data and calls no backends. The NSG retains default outbound rules for APIM dependencies. There is no firewall, VPN, custom DNS, Log Analytics or paid DDoS plan. **Do not use this design as a production baseline.**

## Files

- [Approved plan](.azure/infrastructure-plan.json)
- [Bicep infrastructure](infra/main.bicep)
- [Experiment actions](scripts/Invoke-SubnetExperiment.ps1)
- [Option 2 migration](scripts/Invoke-SubnetMigration.ps1)
- [Comparison of the three alternatives](APIM-SUBNET-EXPANSION-OPTIONS.md)
- [Migration results](APIM-SUBNET-MIGRATION-RESULTS.md)
- [Optional HTTP monitor](scripts/Watch-Gateway.ps1)
- [Offline tests](tests/Test-Local.ps1)
- [Offline migration tests](tests/Test-Migration.ps1)
- [Local configuration template](.env.example)
- [Offline configuration tests](tests/Test-Environment.ps1)

## Local environment configuration

Keep subscription and tenant IDs, resource names and the publisher email in a
root `.env` file. It is ignored by Git and must not be shared. On a fresh clone,
copy [.env.example](.env.example) to `.env` and fill in your lab values. Do not
overwrite an existing populated `.env`.

Generic examples for the subscription and tenant fields:

```dotenv
AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001
AZURE_SUBSCRIPTION_NAME=example-subscription
AZURE_TENANT_ID=00000000-0000-0000-0000-000000000002
```

These are illustrative values, not a working Azure target. Use your actual values
only in the ignored local `.env`.

Both experiment and migration scripts resolve `SubscriptionId`, `ResourceGroup`
and `ApimName` from explicit parameters first, then from `AZURE_SUBSCRIPTION_ID`,
`AZURE_RESOURCE_GROUP` and `APIM_NAME` in `.env`. The default file is relative to
the scripts' project root, independent of the terminal's current directory.
Use `-EnvFile '<absolute-path-to-local-config>'` for a different file. When all
three target parameters are supplied, the scripts do not read an environment file.
Shell environment variables and the Azure CLI default subscription are not used
as fallbacks. Missing or invalid targets fail before Azure calls and run logs.

Use one `KEY=value` per line. Blank lines and full-line `#` comments are allowed.
Matching single or double quotes around values are optional. Values are literal:
there is no interpolation, command execution, escape processing, inline-comment
removal or process-environment modification. Unknown or duplicate keys are rejected.
Use only the keys listed in the example.

For manual commands or the HTTP monitor, load variables in each new terminal
from the project root (this block does not call Azure):

```powershell
. .\scripts\Common.ps1
$settings = Get-LabEnvironment
$lab = Resolve-LabTarget -Overrides @{}
$subscription = $lab.SubscriptionId
$rg = $lab.ResourceGroup
$apim = $lab.ApimName
$location = $settings['AZURE_LOCATION']
$tenant = $settings['AZURE_TENANT_ID']
$email = $settings['APIM_PUBLISHER_EMAIL']
$probeUrl = "https://$apim.azure-api.net/subnet-poc/health"
```

`AZURE_SUBSCRIPTION_NAME` and `LAB_DEPLOYMENT_CORRELATION_ID` are optional
historical metadata, not deployment inputs. The health URL is derived from
`APIM_NAME`. Fixed lab subnet names and CIDRs remain in infrastructure and safety
guards; `.env` does not change the supported topology.

Local configuration is plaintext, not a secret store. Do not add access tokens,
passwords or keys. Logs and snapshots under `artifacts` still contain environment
metadata and remain local-only. Local Git history was restarted with a single
root commit of the current files, excluding earlier commits that contained
environment identifiers. Subscription and tenant examples are synthetic.
Restarting history does not erase existing clones, reflogs, unreachable Git
objects or local evidence. Review all tracked files before public release.

## 1. Prepare and validate locally

Requires PowerShell 7 (`pwsh`), Azure CLI and Bicep CLI. Deployment also requires Azure sign-in, an authorized subscription, registered `Microsoft.Network` and `Microsoft.ApiManagement` providers, and permissions to create, modify and delete lab resources. No script changes the default subscription.

From the project root:

```powershell
pwsh -File .\tests\Test-Local.ps1
pwsh -File .\tests\Test-Migration.ps1
pwsh -File .\tests\Test-Environment.ps1
bicep build .\infra\main.bicep --outfile "$env:TEMP\apim-resize-poc-validation.json"
```

The tests mock Azure CLI to validate safeguards, single-attempt behavior, errors, evidence and calculations. Compiling Bicep or running `what-if` **does not prove** that Azure will allow an occupied subnet to expand.

## 2. Deploy only after approval

**The following commands create billable resources.** Confirm Developer costs, regional availability and subscription policies before proceeding. Charges continue while APIM exists. These instructions describe creating a new lab; the recorded deployment is documented separately below.

Run in PowerShell 7. Load the variables using the local configuration block above.
For a new deployment, choose an unused lab name/group and a region that supports
classic Developer. Do not deploy the initial template against the completed lab.

```powershell
foreach ($key in @('AZURE_LOCATION', 'AZURE_TENANT_ID', 'APIM_PUBLISHER_EMAIL')) {
    if ([string]::IsNullOrWhiteSpace($settings[$key])) { throw "Set $key in .env before deployment." }
}

az login --tenant $tenant
if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed.' }

$exists = az group exists --name $rg --subscription $subscription --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Failed to check the resource group.' }
if ($exists -ne 'false') { throw 'Choose a NEW resource group to avoid changing existing resources.' }

az group create --name $rg --location $location --subscription $subscription `
  --tags purpose=apim-subnet-resize-poc environment=lab
if ($LASTEXITCODE -ne 0) { throw 'Failed to create the resource group.' }

az deployment group what-if --resource-group $rg --subscription $subscription `
  --template-file .\infra\main.bicep `
  --parameters apimName=$apim publisherEmail=$email
if ($LASTEXITCODE -ne 0) { throw 'What-if failed.' }
```

Review `what-if`. After approving the resource creations:

```powershell
az deployment group create --name apim-resize-poc --resource-group $rg `
  --subscription $subscription --template-file .\infra\main.bicep `
  --parameters apimName=$apim publisherEmail=$email
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. Inspect the deployment operations.' }

$probeUrl = az deployment group show --name apim-resize-poc `
  --resource-group $rg --subscription $subscription `
  --query properties.outputs.healthUrl.value --output tsv
if ($LASTEXITCODE -ne 0 -or -not $probeUrl) { throw 'Could not retrieve the endpoint.' }
Invoke-RestMethod -Uri $probeUrl
```

**Do not reapply Bicep during or after the experiment:** it describes the initial /27 state with APIM on the original subnet. Reapplying it would attempt to undo the changes. To repeat from scratch, obtain approval to delete the lab and create another one.

If you deployed the earlier version with two subnets, do not apply this template over it: the direct experiment requires a single-subnet lab. Revising local files does not remove existing Azure resources.

## 3. Attempt to expand the occupied subnet

After deployment finishes and APIM is `Succeeded` on the /27 subnet, run in the operations terminal:

```powershell
$lab = @{
  SubscriptionId = $subscription
  ResourceGroup = $rg
  ApimName = $apim
}
.\scripts\Invoke-SubnetExperiment.ps1 @lab -Action Snapshot
.\scripts\Invoke-SubnetExperiment.ps1 @lab -Action TryResizeOccupied -WhatIf
```

`Snapshot` is read-only in Azure and can diagnose incomplete states. `-WhatIf` queries resources and saves local evidence without changing Azure. This script's only mutating action, `TryResizeOccupied`, checks tags, names, IDs, SKU, topology, APIM attachment to the original subnet and the /27 prefix before requesting confirmation.

The region check accepts equivalent provider representations such as `East US 2` (APIM) and `eastus2` (Network). Missing or different regions remain blocked.

After reviewing the target, run the actual attempt and accept confirmation only for the lab:

```powershell
.\scripts\Invoke-SubnetExperiment.ps1 @lab -Action TryResizeOccupied
```

- **If it fails:** the script stops with an error and preserves Azure's message. Check the code in `result.json` and the Activity Log. Do not assume every failure is `SubnetInUse`.
- **If accepted:** the script records the response and checks /26, APIM `Succeeded` and attachment to the same subnet. Record this as a lab observation, not a guarantee of support or Premium behavior.
- If direct expansion succeeds, **do not shrink an occupied subnet to repeat the test**. A second attempt is blocked because the subnet is already /26. Recreate a /27 lab with approval to repeat from scratch.
- The script submits only one subnet update per attempt and never runs `az apim update`.

### Recovery after failure

- Do not start another change while an Azure operation is running. Closing the terminal does not guarantee cancellation of a submitted operation.
- Inspect the actual state with `Snapshot` and the Activity Log. A subsequent verification failure does not mean expansion was undone.
- If the service is `Failed`, the script blocks further mutations. Resolve the issue through the Azure Portal or support; do not force concurrent changes.
- The direct experiment provides no migration, automatic rollback to /27 or guarantee of IP preservation.

## 4. Option 2: expand using a temporary subnet

Use [Invoke-SubnetMigration.ps1](scripts/Invoke-SubnetMigration.ps1) **only in the classic Developer External lab**. It does not support Premium production environments. It requires one unit, platform stv2, tags `purpose=apim-subnet-resize-poc` and `environment=lab`, default DNS, a managed public IP and no peering, UDR, NAT or subnet delegation.

`Run` sequence:

1. Require APIM `Succeeded` on the original /27, without a temporary subnet or additional subnets.
2. Create `snet-apim-temporary`, `10.90.1.0/27`, with the same NSG.
3. Move APIM while retaining External mode and wait for `Succeeded` on the temporary subnet.
4. Wait until Azure reports no allocations on the original subnet, including IP configurations, private endpoints and service links.
5. Submit a single update of the original subnet to `10.90.0.0/26` and verify the result.
6. Move APIM back and verify attachment, /26, `Succeeded` and the mock.

The script checks HTTP 200 and the exact JSON before and after each stage. A failure stops subsequent stages even if the infrastructure change has already completed. This does not prove continuous availability or private backend connectivity. Azure determines whether the subnet has been released; a rejection does not trigger an automatic retry.

Preparation for the deployed lab, in PowerShell 7:

```powershell
.\scripts\Invoke-SubnetMigration.ps1 -Action Snapshot
.\scripts\Invoke-SubnetMigration.ps1 -Action Run -WhatIf
```

The migration script reads the target from the local `.env` file.
Use `-SubscriptionId`, `-ResourceGroup` and `-ApimName` to override individual
values for another valid lab. `-Action` remains mandatory, and all safeguards
and confirmation remain enabled. The completed lab is already on /26; `Run`
correctly refuses to repeat the initial /27 workflow against that final state.

`-WhatIf` queries state and saves local evidence without creating resources, moving APIM or expanding the subnet. It does not simulate Azure's acceptance of later stages.

**Only after approving the change window, downtime risk and potential IP changes**, run:

```powershell
.\scripts\Invoke-SubnetMigration.ps1 -Action Run
```

- `Run` confirmation covers all four mutating stages. Do not remove confirmation without reviewing the target.
- Each APIM move may take 15 minutes or longer. The default timeout for each wait is 7,200 seconds, with polling every 30 seconds, configurable through `-TimeoutSeconds` and `-PollSeconds`. This timeout neither cancels Azure operations nor interrupts a running CLI call.
- Do not run two script instances or concurrent infrastructure operations. There is no distributed lock against Portal changes or other processes.
- Public and private IPs may change during both moves. Moving back does not guarantee restoration of the old IPs.
- The temporary subnet remains after success. Deletion requires separate assessment and approval.
- **Do not reapply the initial Bicep:** it still declares /27 and one subnet. The direct experiment also blocks a two-subnet topology.

### Evidence and manual continuation

Each execution creates a `Migration-*` directory under `artifacts`, containing the initial snapshot, before/after state for each stage, CLI responses, latest polling snapshot and HTTP evidence. An APIM `--no-wait` submission response may be `null`; the script considers the change complete only after polling and validation.

Detailed logging is enabled by default. Each event is immediately appended to
`migration.log` with its UTC timestamp, level and stage, and displayed in the terminal.
It includes the target, CLI start/end and exit codes, durations, validations,
HTTP status and payload validation, errors, evidence paths and final outcome.
Each poll adds the state, current/target subnet, counter and elapsed time to the log.
The `*-poll.json` file retains only the latest poll. Subnet release polling also
logs each allocation result.

At startup, the script prints the absolute log path and a ready-to-use command
to follow **that execution** in another terminal:

```powershell
Get-Content -LiteralPath '<printed absolute path to migration.log>' -Tail 50 -Wait
```

`Ctrl+C` in the second terminal stops only the log reader. `result.json` also
includes `logPath`. Logs and evidence are written for `Snapshot` and `-WhatIf`.
Do not use `Run` just to open a new log while another execution is active:
editing the script does not add logging to a previously started process.

This log records script actions and queries, rather than Azure's internal events.
A blocking CLI call logs its start and logs completion only when it returns.
The script does not invent a progress percentage or enable `az --debug`.
Use the Portal Activity Log for internal operations. Full JSON responses remain
in the evidence files. Keep the directory private because errors and snapshots
may contain environment metadata.

`result.json` records the current stage, error, `controlPlaneVerifiedStages` (verified infrastructure) and `completedStages` (verified infrastructure and mock). `Verified` indicates success only for the requested stages; for an individual action, it does not mean all of option 2 completed.

After a failure or timeout, inspect `Snapshot`, evidence and the Activity Log. Do not repeat `Run`: it blocks partial states. Wait for any submitted operation to finish and restore the mock before continuing. The script does not remove APIM-managed NICs/VMSS, shrink prefixes or reverse moves.

| Observed state, with infrastructure Succeeded | Next explicit action |
|---|---|
| Original /27, APIM on original, no temporary subnet | `PrepareTemporary` or `Run` |
| Original /27, APIM on original, valid empty temporary subnet | `MoveTemporary` |
| Original /27, APIM on temporary subnet | `ResizeEmpty`, which waits for allocations to be released |
| Empty original /26, APIM on temporary subnet | `MoveBack` |
| Original /26, APIM on original | Infrastructure migration complete; check mock and IPs without repeating changes |
| APIM/network Updating or Failed, unexpected topology | No mutation; investigate through the Portal or support |

For an individual stage, replace `Run` with the action name and run with `-WhatIf` first. A mock failure after moving APIM does not undo the move. Use the actual state with this table rather than relying only on the latest terminal message.

## Optional HTTP monitoring

Monitoring is not required to record Azure's response. To observe the gateway during the attempt, load the local configuration variables in a separate terminal and keep this command running:

```powershell
.\scripts\Watch-Gateway.ps1 `
  -Url $probeUrl `
  -DurationMinutes 180 -IntervalSeconds 5
```

Collect at least 60 seconds of failure-free baseline before the attempt and observe another 60 seconds afterward. The monitor continuously writes CSV and produces a summary when it finishes or handles Ctrl+C normally. An abrupt process termination leaves the CSV already written.

Timed-out requests take up to 10 seconds by default, plus the interval between samples. Sampling frequency is not fixed and cannot determine exact downtime.

## Evidence and success criteria

Each action creates a unique directory under `artifacts`, with UTC timestamps:

| Evidence | Purpose |
|---|---|
| `before.json` / `after.json` | Prefixes, IDs, IPs and provisioning state |
| `operation-response.json` | Response to an accepted mutation |
| `result.json` | Action, start/end, error and outcome |
| `after-error.json` | State after failure, when querying is possible |
| Optional `samples.csv` / `summary.json` | HTTP status, payload validation, error, latency and P95 of successful responses |

`ControlPlaneSucceeded` means only that infrastructure postconditions were verified. **It does not mean the gateway is available.** Correlate operation timestamps with the CSV. `FailedOrRejected` is not a positive result and preserves the error.

The direct PoC aims to **record whether Azure accepts or rejects expansion while APIM is attached**, including the response and before/after states. An occupied-subnet rejection is useful evidence but remains an operation error, not successful expansion.

If accepted, confirm **/26 and APIM `Succeeded` attached to the same subnet ID**. Gateway availability is a separate check. If using the monitor, record the failed-sample percentage, P95 and IP changes. It does not test private backends, load, persistent connections, corporate DNS or IP-based access rules.

Before a Premium production change, validate again in a representative environment with the same SKU, units, regions, zones, NSG/UDR/DNS, backends and allowlists. Confirm support for the desired procedure through Azure documentation or support. Do not interpret the absence of sampled failures as proof of no interruption.

Snapshots contain subscription/network metadata and the publisher's email. Keep `artifacts` private and review it before sharing. Execution artifacts and logs are excluded from Git; links to that evidence require the local files.

## Execution results on September 23, 2026

### Direct occupied-subnet attempt

The classic Developer / External lab was deployed in East US 2.
Azure rejected the single actual expansion attempt from `10.90.0.0/27` to
`10.90.0.0/26` with **`InUsePrefixCannotBeDeleted`** because the original
prefix had active allocations and could not be removed.

At the end of that attempt, the subnet remained /27 and APIM remained
`Succeeded`, attached to the same subnet. The mock returned HTTP 200 and the
expected JSON before and after. These point-in-time checks do not demonstrate
continuous availability. That direct attempt performed no retry, migration,
APIM disconnection or resource deletion.

See the [execution record and evidence](.azure/deployment-plan.md#8-deployment-and-experiment-result).

### Separate option 2 migration

The subsequently authorized temporary-subnet migration completed with outcome
`Verified`, no recorded errors and a total duration of **1 hour, 12 minutes
and 49 seconds**. APIM returned to the original subnet, now `10.90.0.0/26`,
with state `Succeeded` and a successful final HTTP check.

See the [full migration report and stage durations](APIM-SUBNET-MIGRATION-RESULTS.md).
The temporary subnet was retained. These results do not measure total API
downtime or establish Premium availability or behavior. Resources were retained
at completion and incur costs until explicitly approved deletion.

## Explicit cleanup

After saving the evidence, verify the subscription, resource group, its tag and ALL listed resources:

```powershell
az group show --name $rg --subscription $subscription --query '{id:id,tags:tags}'
az resource list --resource-group $rg --subscription $subscription --output table
```

**Only with approval to delete all resources in this lab**, run:

```powershell
az group delete --name $rg --subscription $subscription
if ($LASTEXITCODE -ne 0) { throw 'Deletion failed; resources may continue to incur charges.' }
az group exists --name $rg --subscription $subscription
```

Confirm `false`. Do not remove interactive confirmation and never use this command on a shared group.

## References

- [Subnet changes require moving or removing resources](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-manage-subnet#change-subnet-settings)
- [Classic APIM in an External VNet: NSG and update duration](https://learn.microsoft.com/en-us/azure/api-management/api-management-using-with-vnet)
- [Network requirements, sizing and IP changes](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-injection-resources)
- [API Management Bicep reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.apimanagement/2024-05-01/service)
