#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${1:-} == --help && $# == 1 ]]; then
    cat <<'HELP'
Usage: bash scripts/sh/invoke-subnet-experiment.sh [options]
  --action Snapshot|TryResizeOccupied  Default: Snapshot
  --env-file PATH                     Default: project-root .env (literal data)
  --subscription-id GUID              Override configured subscription
  --resource-group NAME               Override configured lab resource group
  --apim-name NAME                    Override configured lab APIM name
  --output-root PATH                  Default: project-root artifacts
  --what-if                           Read state, validate, but do not mutate
  --yes                               Bypass confirmation for an approved run
  --help                              Show this help without contacting Azure
One occupied /27-to-/26 attempt only. No migration, retry, rollback or deletion.
HELP
    exit 0
fi
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
parse_options "$@"
case $ACTION in Snapshot|TryResizeOccupied) ;; *) fail "Unknown experiment action: $ACTION"; exit 1 ;; esac
require_commands az jq
resolve_lab_target
init_ids
new_run_directory "$ACTION"
LOG_PATH="$RUN_DIRECTORY/experiment.log"
result=$(jq -n --arg action "$ACTION" --arg time "$(utc_now)" \
    '{action:$action,startedAtUtc:$time,finishedAtUtc:null,outcome:"NotStarted",error:null}')

finish() {
    local rc=$? error_snapshot
    trap - EXIT ERR INT TERM
    if (( rc != 0 )); then
        log 'Failure is not automatically proof of a subnet restriction. Inspect the Azure error and evidence.' WARN
        result=$(jq --arg error "Operation failed (exit $rc). See experiment.log for Azure diagnostics." \
            '.outcome="FailedOrRejected" | .error=$error' <<< "$result")
        if error_snapshot=$(snapshot); then
            save_evidence after-error.json "$error_snapshot" || log 'Could not save error snapshot.' WARN
        else log 'Could not capture state after failure.' WARN; fi
    fi
    result=$(jq --arg time "$(utc_now)" '.finishedAtUtc=$time' <<< "$result")
    save_evidence result.json "$result" || rc=1
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

before=$(snapshot)
save_evidence before.json "$before"
if [[ $ACTION == Snapshot ]]; then
    result=$(jq '.outcome="SnapshotOnly"' <<< "$result")
    printf '%s\n' "$before"
    exit 0
fi
assert_lab_state "$before"
jq -e --arg id "$ORIGINAL_ID" '
    (.apim.virtualNetworkConfiguration.subnetResourceId | ascii_downcase) == ($id | ascii_downcase)
    and .original.addressPrefix == "10.90.0.0/27"
' <<< "$before" >/dev/null || { fail 'Occupied resize requires APIM on the original /27 subnet.'; exit 1; }
if ! confirm_mutation "$SUBSCRIPTION_ID / $RESOURCE_GROUP / $APIM_NAME: TryResizeOccupied; downtime and IP changes possible."; then
    result=$(jq '.outcome="Skipped"' <<< "$result")
    exit 0
fi
result=$(jq '.outcome="InProgress"' <<< "$result")
save_evidence result.json "$result"
response=$(az_json network vnet subnet update --vnet-name vnet-apim-resize-poc \
    --name snet-apim-original --address-prefixes 10.90.0.0/26 "${SCOPE[@]}")
save_evidence operation-response.json "$response"
after=$(snapshot)
save_evidence after.json "$after"
assert_lab_state "$after"
jq -e --arg id "$ORIGINAL_ID" '
    .original.addressPrefix == "10.90.0.0/26" and
    (.apim.virtualNetworkConfiguration.subnetResourceId | ascii_downcase) == ($id | ascii_downcase)
' <<< "$after" >/dev/null || { fail 'Postcondition failed: prefix or APIM subnet differs from the expected result.'; exit 1; }
result=$(jq '.outcome="ControlPlaneSucceeded"' <<< "$result")
log 'Control-plane postconditions verified. Gateway availability must be checked separately.'
