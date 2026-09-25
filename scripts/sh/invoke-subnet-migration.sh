#!/usr/bin/env bash
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    printf '%s\n' 'Bash 4 or newer is required.' >&2
    exit 1
fi

usage() {
    cat <<'HELP'
Usage: bash scripts/sh/invoke-subnet-migration.sh [options]

Native Bash migration for the isolated classic Developer External APIM lab.
  --action ACTION            Snapshot (default), Run, PrepareTemporary,
                             MoveTemporary, ResizeEmpty, or MoveBack
  --env-file PATH            Operational configuration (default: repository .env)
  --subscription-id GUID     Explicit lab subscription
  --resource-group NAME      Explicit lab resource group
  --apim-name NAME           Explicit lab APIM name
  --output-root PATH         Local evidence directory (default: artifacts)
  --timeout-seconds N        Timeout per wait, 1-14400 (default: 7200)
  --poll-seconds N           Poll interval, 1-120 (default: 30)
  --what-if                  Read Azure and save evidence, without mutations
  --yes                      Bypass confirmation for an explicitly approved run
  --help                     Show help without contacting Azure

Mutations may cause downtime and IP changes. No automatic retry, rollback,
shrinking, or deletion is performed. Temporary subnet is retained. A timed-out
Azure operation may still be running. Inspect Snapshot and evidence to recover;
do not run concurrent mutations or blindly repeat Run.
HELP
}

for argument in "$@"; do
    if [[ $argument == --help ]]; then
        usage
        exit 0
    fi
done

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIRECTORY/common.sh"

parse_options "$@"
ACTION=${ACTION:-Snapshot}
case "$ACTION" in
    Snapshot|Run|PrepareTemporary|MoveTemporary|ResizeEmpty|MoveBack) ;;
    *) fail "Unknown migration action: $ACTION"; exit 1 ;;
esac
require_integer "$TIMEOUT_SECONDS" 1 14400 TimeoutSeconds
require_integer "$POLL_SECONDS" 1 120 PollSeconds
require_commands az jq curl
resolve_lab_target
init_ids
new_run_directory "Migration-$ACTION"
LOG_PATH="$RUN_DIRECTORY/migration.log"
STAGE=Preflight
RUN_STARTED=$SECONDS
MAIN_PID=$BASHPID
ERROR_MESSAGE=''
RECOVERY='Inspect live Snapshot and evidence. No automatic retry, rollback, shrinking or deletion. A timed-out operation may still be running.'
RESULT=$(jq -n --arg action "$ACTION" --arg started "$(utc_now)" \
    --arg logPath "$LOG_PATH" --arg recovery "$RECOVERY" '{
        action: $action, startedAtUtc: $started, finishedAtUtc: null,
        outcome: "NotStarted", stage: "Preflight", completedStages: [],
        controlPlaneVerifiedStages: [], error: null, logPath: $logPath,
        recovery: $recovery
    }')

on_error() {
    local status=$1 line=$2 command=$3
    # Substitutions inherit ERR, but only the entrypoint owns failure evidence.
    if [[ $BASHPID != "$MAIN_PID" ]]; then
        return "$status"
    fi
    ERROR_MESSAGE="Command failed (exit $status) at line $line: $command"
    exit "$status"
}

on_signal() {
    ERROR_MESSAGE="Interrupted by $1. An Azure operation may still be running."
    exit "$2"
}

on_exit() {
    local status=$1 after_error updated
    [[ $BASHPID == "$MAIN_PID" ]] || return "$status"
    trap - ERR EXIT INT TERM
    if (( status != 0 )); then
        ERROR_MESSAGE=${ERROR_MESSAGE:-"Migration stopped with exit status $status."}
        if updated=$(jq --arg error "$ERROR_MESSAGE" --arg stage "$STAGE" \
            '.outcome = "Failed" | .error = $error | .stage = $stage' <<<"$RESULT"); then
            RESULT=$updated
        else
            printf '%s\n' 'Could not update failure result.' >&2
        fi
        log "$ERROR_MESSAGE" ERROR || printf '%s\n' "$ERROR_MESSAGE" >&2
        log "$RECOVERY" WARN || printf '%s\n' "$RECOVERY" >&2
        save_evidence result.json "$RESULT" ||
            printf '%s\n' 'Could not save intermediate failure result.' >&2
        if after_error=$(snapshot true); then
            if ! save_evidence after-error.json "$after_error"; then
                log 'Could not save error snapshot.' WARN ||
                    printf '%s\n' 'Could not save error snapshot.' >&2
            fi
        else
            log 'Could not capture error snapshot.' WARN ||
                printf '%s\n' 'Could not capture error snapshot.' >&2
        fi
    fi
    if updated=$(jq --arg finished "$(utc_now)" '.finishedAtUtc = $finished' <<<"$RESULT"); then
        RESULT=$updated
    else
        printf '%s\n' 'Could not set result completion timestamp.' >&2
        status=1
    fi
    if ! save_evidence result.json "$RESULT"; then
        printf '%s\n' 'Could not save final migration result.' >&2
        status=1
    fi
    if ! log "Outcome=$(jq -r '.outcome' <<<"$RESULT"); elapsed=$((SECONDS - RUN_STARTED))s; completedStages=$(jq -r '.completedStages | join(",")' <<<"$RESULT")"; then
        printf '%s\n' 'Could not write final migration log.' >&2
        status=1
    fi
    exit "$status"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap 'on_exit "$?"' EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

assert_migration_state() {
    local state=$1
    assert_lab_state "$state" true || return
    if ! jq -e '
        def populated: (. // []) | map(select(. != null)) | length > 0;
        .apim.sku.capacity == 1 and .apim.platformVersion == "stv2" and
        ((.apim.publicIpAddressId // "") == "") and
        (.apim.privateEndpointConnections | populated | not) and
        (.vnet.dhcpOptions.dnsServers | populated | not)
    ' <<<"$state" >/dev/null; then
        fail 'Only the single-unit stv2 lab with managed public IP and default DNS is supported.'
        return 1
    fi
    if ! jq -e 'all(.group, .apim, .vnet; .tags.environment == "lab")' <<<"$state" >/dev/null; then
        fail 'Migration requires environment=lab tags.'
        return 1
    fi
}

assert_migration_stage() {
    local stage=$1 state=$2 original temporary subnet prefix
    assert_migration_state "$state" || return
    subnet=$(jq -r '.apim.virtualNetworkConfiguration.subnetResourceId' <<<"$state") || return
    prefix=$(jq -r '.original.addressPrefix' <<<"$state") || return
    original=$(jq -c '.original' <<<"$state") || return
    temporary=$(jq -c '.temporary // null' <<<"$state") || return
    case "$stage" in
        Run|PrepareTemporary)
            if [[ ${subnet,,} != "${ORIGINAL_ID,,}" || $prefix != 10.90.0.0/27 || $temporary != null ]]; then
                fail 'Start requires APIM on original /27 and no temporary subnet. Use explicit stages to resume.'
                return 1
            fi
            ;;
        MoveTemporary)
            if [[ ${subnet,,} != "${ORIGINAL_ID,,}" || $prefix != 10.90.0.0/27 || $temporary == null ]] ||
                has_allocations "$temporary"; then
                fail 'MoveTemporary requires APIM on original /27 and an empty temporary subnet.'
                return 1
            fi
            ;;
        ResizeEmpty)
            if [[ ${subnet,,} != "${TEMPORARY_ID,,}" || $temporary == null || $prefix != 10.90.0.0/27 ]]; then
                fail 'ResizeEmpty requires APIM on temporary and original /27.'
                return 1
            fi
            ;;
        MoveBack)
            if [[ ${subnet,,} != "${TEMPORARY_ID,,}" || $temporary == null || $prefix != 10.90.0.0/26 ]] ||
                has_allocations "$original"; then
                fail 'MoveBack requires APIM on temporary and empty original /26.'
                return 1
            fi
            ;;
        *) fail "Unknown migration stage: $stage"; return 1 ;;
    esac
}

write_migration_state() {
    local summary
    summary=$(jq -r '"State: APIM=\(.apim.provisioningState); subnet=\(.apim.virtualNetworkConfiguration.subnetResourceId); originalPrefix=\(.original.addressPrefix); temporaryExists=\(.temporary != null)"' <<<"$1") || return
    log "$summary"
}

wait_apim_subnet() {
    local target=$1 started=$SECONDS deadline=$((SECONDS + TIMEOUT_SECONDS))
    local poll=0 apim provisioning subnet remaining delay
    log "Waiting for APIM Succeeded; target=$target; timeout=${TIMEOUT_SECONDS}s" || return
    while :; do
        poll=$((poll + 1))
        apim=$(az_json apim show --name "$APIM_NAME" "${SCOPE[@]}") || return
        save_evidence "$STAGE-poll.json" "$apim" || return
        provisioning=$(jq -r '.provisioningState' <<<"$apim") || return
        subnet=$(jq -r '.virtualNetworkConfiguration.subnetResourceId' <<<"$apim") || return
        log "Poll #$poll: state=$provisioning; subnet=$subnet; target=$target; elapsed=$((SECONDS - started))s/${TIMEOUT_SECONDS}s" || return
        case "${provisioning,,}" in
            failed|canceled|deleting|terminating)
                fail "APIM entered terminal state $provisioning."
                return 1
                ;;
        esac
        if [[ ${provisioning,,} == succeeded && ${subnet,,} == "${target,,}" ]]; then
            log 'APIM target subnet and Succeeded state verified.'
            return
        fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        delay=$POLL_SECONDS
        (( delay <= remaining )) || delay=$remaining
        log "Next poll in ${delay}s; do not resubmit the update." || return
        sleep "$delay" || return
        (( SECONDS < deadline )) || break
    done
    fail "Timeout waiting for APIM on $target. Operation may still be running; do not repeat the update."
    return 1
}

wait_original_empty() {
    local started=$SECONDS deadline=$((SECONDS + TIMEOUT_SECONDS))
    local poll=0 state original allocated remaining delay
    log "Waiting for original subnet allocations to be released; timeout=${TIMEOUT_SECONDS}s" || return
    while :; do
        poll=$((poll + 1))
        state=$(snapshot true) || return
        save_evidence ResizeEmpty-release-poll.json "$state" || return
        assert_migration_stage ResizeEmpty "$state" || return
        original=$(jq -c '.original' <<<"$state") || return
        allocated=false
        if has_allocations "$original"; then allocated=true; fi
        log "Release poll #$poll: originalAllocated=$allocated; elapsed=$((SECONDS - started))s/${TIMEOUT_SECONDS}s" || return
        if [[ $allocated == false ]]; then
            log 'Original subnet verified empty; prefix update may proceed.' || return
            printf '%s\n' "$state"
            return 0
        fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        delay=$POLL_SECONDS
        (( delay <= remaining )) || delay=$remaining
        log "Next poll in ${delay}s; original subnet still has allocations." || return
        sleep "$delay" || return
        (( SECONDS < deadline )) || break
    done
    fail 'Timeout waiting for original subnet allocations. No prefix update was issued.'
    return 1
}

invoke_migration_stage() {
    STAGE=$1
    local started=$SECONDS state response after target expected_prefix nsg temporary
    RESULT=$(jq --arg stage "$STAGE" '.stage = $stage' <<<"$RESULT") || return
    log 'Stage started' || return
    save_evidence result.json "$RESULT" || return
    state=$(snapshot true) || return
    save_evidence "$STAGE-before.json" "$state" || return
    write_migration_state "$state" || return
    assert_migration_stage "$STAGE" "$state" || return
    log 'Stage safety checks passed.' || return
    assert_mock_health "$STAGE-http-before" || return
    case "$STAGE" in
        PrepareTemporary)
            log 'Creating temporary subnet 10.90.1.0/27 with the original NSG.' || return
            nsg=$(jq -r '.original.networkSecurityGroup.id' <<<"$state") || return
            response=$(az_json network vnet subnet create --vnet-name vnet-apim-resize-poc \
                --name snet-apim-temporary --address-prefixes 10.90.1.0/27 \
                --network-security-group "$nsg" "${SCOPE[@]}") || return
            ;;
        MoveTemporary|MoveBack)
            target=$ORIGINAL_ID
            [[ $STAGE != MoveTemporary ]] || target=$TEMPORARY_ID
            log "Submitting APIM move to $target; submission is not completion." || return
            response=$(az_json --allow-empty apim update --name "$APIM_NAME" \
                --virtual-network External --set "virtualNetworkConfiguration.subnetResourceId=$target" \
                --no-wait "${SCOPE[@]}") || return
            save_evidence "$STAGE-response.json" "$response" || return
            wait_apim_subnet "$target" || return
            ;;
        ResizeEmpty)
            state=$(wait_original_empty) || return
            save_evidence ResizeEmpty-verified-empty.json "$state" || return
            log 'Expanding verified-empty original subnet from 10.90.0.0/27 to 10.90.0.0/26.' || return
            response=$(az_json network vnet subnet update --vnet-name vnet-apim-resize-poc \
                --name snet-apim-original --address-prefixes 10.90.0.0/26 "${SCOPE[@]}") || return
            ;;
    esac
    save_evidence "$STAGE-response.json" "$response" || return
    after=$(snapshot true) || return
    save_evidence "$STAGE-after.json" "$after" || return
    write_migration_state "$after" || return
    assert_migration_state "$after" || return
    target=$ORIGINAL_ID
    expected_prefix=10.90.0.0/27
    case "$STAGE" in MoveTemporary|ResizeEmpty) target=$TEMPORARY_ID ;; esac
    case "$STAGE" in ResizeEmpty|MoveBack) expected_prefix=10.90.0.0/26 ;; esac
    if ! jq -e --arg subnet "$target" --arg prefix "$expected_prefix" '
        .temporary != null and .original.addressPrefix == $prefix and
        ((.apim.virtualNetworkConfiguration.subnetResourceId | ascii_downcase) == ($subnet | ascii_downcase))
    ' <<<"$after" >/dev/null; then
        fail "Postcondition failed after $STAGE."
        return 1
    fi
    temporary=$(jq -c '.temporary' <<<"$after") || return
    if [[ $STAGE == PrepareTemporary ]] && has_allocations "$temporary"; then
        fail 'New temporary subnet unexpectedly has allocations.'
        return 1
    fi
    RESULT=$(jq --arg stage "$STAGE" '.controlPlaneVerifiedStages += [$stage]' <<<"$RESULT") || return
    log 'Control-plane postconditions verified; checking gateway health next.' || return
    save_evidence result.json "$RESULT" || return
    assert_mock_health "$STAGE-http-after" || return
    RESULT=$(jq --arg stage "$STAGE" '.completedStages += [$stage]' <<<"$RESULT") || return
    save_evidence result.json "$RESULT" || return
    log "Stage verified; elapsed=$((SECONDS - started))s"
}

log "Action=$ACTION; subscription=$SUBSCRIPTION_ID; resourceGroup=$RESOURCE_GROUP; APIM=$APIM_NAME"
log "Evidence: $RUN_DIRECTORY"
log "Log: $LOG_PATH"
log "Poll interval=${POLL_SECONDS}s; timeout per wait=${TIMEOUT_SECONDS}s. CLI calls can take longer; Azure operations are not canceled on timeout."
save_evidence result.json "$RESULT"
log 'Reading initial Azure state.'
before=$(snapshot true)
save_evidence before.json "$before"
if [[ $ACTION == Snapshot ]]; then
    RESULT=$(jq '.outcome = "SnapshotOnly"' <<<"$RESULT")
    log 'Read-only snapshot captured; inspect before.json for resource state.'
    printf '%s\n' "$before"
    exit 0
fi
write_migration_state "$before"
assert_migration_stage "$ACTION" "$before"
log 'Preflight safety checks passed. Requesting approval (or evaluating --what-if); no mutation submitted yet.'
if ! confirm_mutation "$ACTION: $SUBSCRIPTION_ID / $RESOURCE_GROUP / $APIM_NAME; lab-only temporary subnet migration; downtime and IP changes possible; temporary subnet retained"; then
    RESULT=$(jq '.outcome = "Skipped"' <<<"$RESULT")
    log 'Skipped: confirmation declined or --what-if; no Azure mutation submitted.'
    exit 0
fi
RESULT=$(jq '.outcome = "InProgress"' <<<"$RESULT")
log 'Approved; beginning requested migration stages.'
stages=("$ACTION")
if [[ $ACTION == Run ]]; then
    stages=(PrepareTemporary MoveTemporary ResizeEmpty MoveBack)
fi
for stage in "${stages[@]}"; do
    invoke_migration_stage "$stage"
done
RESULT=$(jq '.outcome = "Verified"' <<<"$RESULT")
log 'Requested stages verified, including point-in-time mock health. Temporary subnet retained; no cleanup performed.'
