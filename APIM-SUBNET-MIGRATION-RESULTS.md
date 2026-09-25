# APIM subnet migration and expansion results

**Date:** September 23, 2026

**Outcome:** `Verified`, no recorded errors

**Total duration:** 1 hour, 12 minutes and 49 seconds (rounded)

The execution moved APIM to a temporary subnet, waited for the original subnet to be released, expanded its prefix from `/27` to `/26`, and moved APIM back. The script completed and verified all four stages.

## Environment

| Resource | Value |
|---|---|
| Subscription | Local `.env`: `AZURE_SUBSCRIPTION_ID` |
| Resource group | Local `.env`: `AZURE_RESOURCE_GROUP` |
| APIM | Local `.env`: `APIM_NAME` |
| Region | East US 2 |
| Configuration | Developer, one unit, platform `stv2`, External VNet |
| VNet | `vnet-apim-resize-poc` |
| Original subnet | `snet-apim-original` |
| Temporary subnet | `snet-apim-temporary`, prefix `10.90.1.0/27` |
| Scope | Proof of concept in a lab environment |

For current script usage, see [local environment configuration](README.md#local-environment-configuration).
Operational scripts read `.env`; [offline tests](README.md#offline-test-configuration)
read a separate synthetic `.env.test`. Offline test results do not replace the
historical Azure execution evidence summarized here.

This recorded execution used PowerShell. A [native Bash equivalent](README.md#native-bash-usage)
is also available, with local mocked validation only; it has not been run against
Azure and does not add new cloud execution evidence to this report.

The current PowerShell entrypoint is
[scripts/ps1/Invoke-SubnetMigration.ps1](scripts/ps1/Invoke-SubnetMigration.ps1);
the Bash counterpart is
[scripts/sh/invoke-subnet-migration.sh](scripts/sh/invoke-subnet-migration.sh).
These are current source locations, not immutable copies of the historical
execution. Folder reorganization does not change the evidence paths, recorded
timestamps or outcomes below. See the
[shell comparison](README.md#choosing-powershell-or-bash) for prerequisites and
parameter mappings, and do not rerun `Run` on the already-expanded lab.

## Duration and stages

The `Run` execution started on **September 23, 2026, at 14:16:38** and finished at **15:29:26**, in **UTC-3**. The exact UTC timestamps are `2026-09-23T17:16:38.0116511Z` and `2026-09-23T18:29:26.6558675Z`; the difference is **4,368.644 seconds**.

| Stage | Start (UTC-3) | End (UTC-3) | Approximate duration |
|---|---|---|---|
| Initialization and initial checks | 14:16:38 | 14:17:19 | 42 s |
| `PrepareTemporary`: prepare the temporary subnet | 14:17:19 | 14:17:50 | 30 s |
| `MoveTemporary`: move APIM to the temporary subnet and validate | 14:17:50 | 14:42:09 | 24 min 19 s |
| `ResizeEmpty`: wait for release and expand the original subnet | 14:42:09 | 15:02:40 | 20 min 31 s |
| `MoveBack`: return APIM to the original subnet and validate | 15:02:40 | 15:29:26 | 26 min 46 s |

Table timestamps omit fractional seconds. Durations are rounded individually; the total uses the execution's exact timestamps.

### Waiting for the original subnet to be released

- At **15:02:24 (UTC-3)**, the script confirmed that the original subnet had no allocations.
- Only after that check did the script start changing `10.90.0.0/27` to `10.90.0.0/26`.
- At **15:02:40 (UTC-3)**, the expansion stage was verified.
- The change and its verification took approximately **16 seconds** after confirming the subnet was empty. Most of `ResizeEmpty` was spent waiting for release.
- The old NIC reference remained on the original subnet even after APIM finished moving to the temporary subnet. The execution waited for its removal without bypassing the allocation check. The evidence does not establish the internal cause of this delay.

## Verified final state

| Check | Result |
|---|---|
| Execution outcome | `Verified` |
| Completed stages | `PrepareTemporary`, `MoveTemporary`, `ResizeEmpty`, `MoveBack` |
| APIM state | `Succeeded` |
| APIM configured subnet | `snet-apim-original` |
| Original subnet prefix | `10.90.0.0/26` |
| Original subnet state | `Succeeded` |
| Final HTTP check | HTTP `200`, `success: true`, no error |
| HTTP check time | 15:29:23 (UTC-3) |

Endpoint used for the HTTP check:

```text
https://<APIM_NAME>.azure-api.net/subnet-poc/health
```

The instance name is retained in local `.env`; the original URL and resource
identifiers remain in the private execution evidence. Current configuration
may change; historical evidence remains the source for the recorded run.

The temporary subnet was retained. The final snapshot still contained a NIC reference on it; migration completion does not prove that allocation cleanup finished. Check dependencies and allocations again before any manual removal.

## Limitations

- Total duration measures this script execution, including checks and waits. It excludes initial lab creation and earlier attempts.
- **Total duration does not represent API downtime.** Point-in-time HTTP checks do not measure continuous availability.
- These results document one lab execution in this configuration and do not guarantee duration for other instances or environments.
- The final state reflects evidence saved at execution completion. No new Azure query was performed to generate this report.

## Evidence

Execution logs and artifacts are excluded from Git. The evidence links below require the local files and are not available in a fresh clone.

- [Execution outcome and timestamps](artifacts/20260923T171638009Z-Migration-Run-46c7dcf63e194f4d82019382d979b48b/result.json)
- [Complete log with stage timestamps and durations](artifacts/20260923T171638009Z-Migration-Run-46c7dcf63e194f4d82019382d979b48b/migration.log)
- [Final APIM and subnet snapshot](artifacts/20260923T171638009Z-Migration-Run-46c7dcf63e194f4d82019382d979b48b/MoveBack-after.json)
- [Final HTTP check result](artifacts/20260923T171638009Z-Migration-Run-46c7dcf63e194f4d82019382d979b48b/MoveBack-http-after.json)
- [PowerShell migration script, current source location](scripts/ps1/Invoke-SubnetMigration.ps1)
