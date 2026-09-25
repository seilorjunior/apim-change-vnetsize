#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'ERROR: Bash 4 or newer is required.\n' >&2
    return 1
fi

LAB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
declare -A ENV_VALUES=()

utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
    local entry
    entry="[$(utc_now)] [${2:-INFO}] [${STAGE:-Preflight}] $1"
    printf '%s\n' "$entry" >&2
    if [[ -n ${LOG_PATH:-} ]]; then
        printf '%s\n' "$entry" >> "$LOG_PATH" || return 1
    fi
}

fail() { log "$1" ERROR; return 1; }

require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || { fail "Required command not found: $command"; return 1; }
    done
}

trim() {
    local text=$1
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

load_environment() {
    local file=$1 line text key value quote number=0
    ENV_VALUES=()
    [[ -f $file && -r $file ]] || { fail "Environment file not found or unreadable: $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        if (( number == 1 )); then line=${line#$'\xef\xbb\xbf'}; fi
        text=$(trim "$line")
        [[ -z $text || $text == \#* ]] && continue
        [[ $text =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || { fail "Invalid environment syntax at line $number. Use KEY=value."; return 1; }
        key=${BASH_REMATCH[1]}
        value=$(trim "${BASH_REMATCH[2]}")
        case $key in
            AZURE_SUBSCRIPTION_ID|AZURE_SUBSCRIPTION_NAME|AZURE_TENANT_ID|AZURE_LOCATION|AZURE_RESOURCE_GROUP|APIM_NAME|APIM_PUBLISHER_EMAIL|LAB_DEPLOYMENT_CORRELATION_ID) ;;
            *) fail "Unknown environment key at line $number: $key"; return 1 ;;
        esac
        [[ ! ${ENV_VALUES[$key]+present} ]] || { fail "Duplicate environment key at line $number: $key"; return 1; }
        quote=${value:0:1}
        if [[ $quote == '"' || $quote == "'" ]]; then
            [[ ${#value} -ge 2 && ${value: -1} == "$quote" ]] || { fail "Unclosed environment quote at line $number."; return 1; }
            value=${value:1:${#value}-2}
        fi
        ENV_VALUES[$key]=$value
    done < "$file"
}

require_integer() {
    local value=$1 min=$2 max=$3 name=$4
    [[ $value =~ ^[0-9]+$ && ${#value} -le 9 ]] &&
        (( 10#$value >= min && 10#$value <= max )) ||
        { fail "$name must be an integer between $min and $max."; return 1; }
}

parse_options() {
    ACTION=Snapshot ENV_FILE="$LAB_ROOT/.env" OUTPUT_ROOT="$LAB_ROOT/artifacts"
    SUBSCRIPTION_ID= RESOURCE_GROUP= APIM_NAME= URL=
    SUBSCRIPTION_SET=false RESOURCE_GROUP_SET=false APIM_NAME_SET=false URL_SET=false
    WHAT_IF=false YES=false TIMEOUT_SECONDS=7200 POLL_SECONDS=30
    DURATION_MINUTES=180 INTERVAL_SECONDS=5 REQUEST_TIMEOUT_SECONDS=10
    local option value kind
    local -A seen=()
    case ${0##*/} in
        invoke-subnet-experiment.sh) kind=experiment ;;
        invoke-subnet-migration.sh) kind=migration ;;
        watch-gateway.sh) kind=monitor ;;
        *) kind=shared ;;
    esac
    while (( $# )); do
        option=$1
        [[ ! ${seen[$option]+present} ]] || { fail "Duplicate option: $option"; return 1; }
        seen[$option]=true
        case $option in
            --yes|--what-if)
                [[ $kind != monitor ]] || { fail "Unsupported monitor option: $option"; return 1; }
                if [[ $option == --yes ]]; then YES=true; else WHAT_IF=true; fi
                shift; continue ;;
            --env-file|--output-root) ;;
            --action|--subscription-id|--resource-group|--apim-name)
                [[ $kind != monitor ]] || { fail "Unsupported monitor option: $option"; return 1; } ;;
            --timeout-seconds|--poll-seconds)
                [[ $kind == migration || $kind == shared ]] || { fail "Unsupported option: $option"; return 1; } ;;
            --url|--duration-minutes|--interval-seconds|--request-timeout-seconds)
                [[ $kind == monitor || $kind == shared ]] || { fail "Unsupported option: $option"; return 1; } ;;
            *) fail "Unknown option: $option. Use --help."; return 1 ;;
        esac
        [[ $# -ge 2 && $2 != --* ]] || { fail "Missing value for $option."; return 1; }
        value=$2
        case $option in
            --action) ACTION=$value ;;
            --env-file) ENV_FILE=$value ;;
            --output-root) OUTPUT_ROOT=$value ;;
            --subscription-id) SUBSCRIPTION_ID=$value; SUBSCRIPTION_SET=true ;;
            --resource-group) RESOURCE_GROUP=$value; RESOURCE_GROUP_SET=true ;;
            --apim-name) APIM_NAME=$value; APIM_NAME_SET=true ;;
            --url) URL=$value; URL_SET=true ;;
            --timeout-seconds) require_integer "$value" 1 14400 "$option" || return 1; TIMEOUT_SECONDS=$((10#$value)) ;;
            --poll-seconds) require_integer "$value" 1 120 "$option" || return 1; POLL_SECONDS=$((10#$value)) ;;
            --duration-minutes) require_integer "$value" 1 1440 "$option" || return 1; DURATION_MINUTES=$((10#$value)) ;;
            --interval-seconds) require_integer "$value" 1 60 "$option" || return 1; INTERVAL_SECONDS=$((10#$value)) ;;
            --request-timeout-seconds) require_integer "$value" 1 120 "$option" || return 1; REQUEST_TIMEOUT_SECONDS=$((10#$value)) ;;
        esac
        shift 2
    done
    [[ -n $OUTPUT_ROOT && -n $ENV_FILE ]] || { fail 'Environment and output paths must not be empty.'; return 1; }
}

validate_target() {
    [[ $SUBSCRIPTION_ID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ &&
       $SUBSCRIPTION_ID != 00000000-0000-0000-0000-000000000000 ]] ||
        { fail 'Subscription ID must be a non-empty GUID.'; return 1; }
    [[ $RESOURCE_GROUP =~ ^rg-apim-resize-poc[-a-zA-Z0-9]*$ &&
       $APIM_NAME =~ ^apim-resize-poc-[a-zA-Z0-9-]+$ ]] ||
        { fail 'Resource group and APIM name must use the required lab prefixes.'; return 1; }
    SUBSCRIPTION_ID=${SUBSCRIPTION_ID,,}
}

resolve_lab_target() {
    if [[ $SUBSCRIPTION_SET != true || $RESOURCE_GROUP_SET != true || $APIM_NAME_SET != true ]]; then
        load_environment "$ENV_FILE" || return 1
    fi
    if [[ $SUBSCRIPTION_SET != true ]]; then SUBSCRIPTION_ID=${ENV_VALUES[AZURE_SUBSCRIPTION_ID]:-}; fi
    if [[ $RESOURCE_GROUP_SET != true ]]; then RESOURCE_GROUP=${ENV_VALUES[AZURE_RESOURCE_GROUP]:-}; fi
    if [[ $APIM_NAME_SET != true ]]; then APIM_NAME=${ENV_VALUES[APIM_NAME]:-}; fi
    validate_target
}

init_ids() {
    ROOT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
    VNET_ID="$ROOT_ID/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
    ORIGINAL_ID="$VNET_ID/subnets/snet-apim-original"
    TEMPORARY_ID="$VNET_ID/subnets/snet-apim-temporary"
    NSG_ID="$ROOT_ID/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-resize-poc"
    SCOPE=(--subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP")
}

new_run_directory() {
    umask 077
    mkdir -p -- "$OUTPUT_ROOT" || return 1
    RUN_DIRECTORY=$(mktemp -d "$OUTPUT_ROOT/$(date -u '+%Y%m%dT%H%M%SZ')-$1-XXXXXXXX") || return 1
    RUN_DIRECTORY=$(cd -- "$RUN_DIRECTORY" && pwd) || return 1
    log "Evidence: $RUN_DIRECTORY"
}

save_evidence() {
    printf '%s\n' "$2" | jq '.' > "$RUN_DIRECTORY/$1"
}

az_json() {
    local allow_empty=false output rc errors diagnostics
    if [[ ${1:-} == --allow-empty ]]; then allow_empty=true; shift; fi
    log "CLI START: az $* --only-show-errors --output json" || return 1
    errors=$(mktemp "$RUN_DIRECTORY/cli-error-XXXXXXXX") || return 1
    # Disable MSYS conversion of ARM IDs when using Azure CLI from Git Bash.
    if output=$(MSYS_NO_PATHCONV=1 az "$@" --only-show-errors --output json 2>"$errors"); then rc=0; else rc=$?; fi
    diagnostics=$(<"$errors")
    rm -f -- "$errors" || return 1
    if [[ -n $diagnostics ]]; then log "$diagnostics" WARN || return 1; fi
    log "CLI END: exit=$rc" || return 1
    if (( rc != 0 )); then
        fail "Azure CLI exit code $rc. Command: az $*
$diagnostics
$output"
        return "$rc"
    fi
    if [[ -z $(trim "$output") ]]; then
        [[ $allow_empty == true ]] || { fail 'Azure CLI returned no JSON.'; return 1; }
        log 'No response body; submission is not completion.' || return 1
        printf 'null\n'
        return
    fi
    printf '%s\n' "$output" | jq -s --argjson allow "$allow_empty" '
        if length == 1 and (.[0] != null or $allow) then .[0]
        else error("Expected one nonempty JSON response") end'
}

snapshot() {
    local include_temporary=${1:-false} group apim vnet original temporary=null
    group=$(az_json group show --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID") || return 1
    apim=$(az_json apim show --name "$APIM_NAME" "${SCOPE[@]}") || return 1
    vnet=$(az_json network vnet show --name vnet-apim-resize-poc "${SCOPE[@]}") || return 1
    original=$(az_json network vnet subnet show --vnet-name vnet-apim-resize-poc --name snet-apim-original "${SCOPE[@]}") || return 1
    if [[ $include_temporary == true ]] &&
        jq -e --arg id "$TEMPORARY_ID" 'any(.subnets[]?; (.id | ascii_downcase) == ($id | ascii_downcase))' <<< "$vnet" >/dev/null; then
        temporary=$(az_json network vnet subnet show --vnet-name vnet-apim-resize-poc --name snet-apim-temporary "${SCOPE[@]}") || return 1
    fi
    jq -n --arg time "$(utc_now)" --argjson group "$group" --argjson apim "$apim" \
        --argjson vnet "$vnet" --argjson original "$original" --argjson temporary "$temporary" \
        --argjson include "$include_temporary" \
        '{capturedAtUtc:$time,group:$group,apim:$apim,vnet:$vnet,original:$original}
         + (if $include then {temporary:$temporary} else {} end)'
}

assert_lab_state() {
    local state=$1 temporary=${2:-false}
    jq -e --arg root "$ROOT_ID" --arg vnet "$VNET_ID" --arg original "$ORIGINAL_ID" \
        --arg temporary "$TEMPORARY_ID" --arg nsg "$NSG_ID" --arg apim "$APIM_NAME" \
        --argjson allow "$temporary" '
        def eqi($v): type == "string" and ascii_downcase == ($v | ascii_downcase);
        def empty_items: . == null or . == [];
        def subnet_ok:
            (.networkSecurityGroup.id | eqi($nsg)) and
            (.delegations | empty_items) and (.addressPrefixes | empty_items) and
            (.routeTable == null) and (.natGateway == null);
        . as $s |
        ([$original] + (if $allow and .temporary != null then [$temporary] else [] end)) as $ids |
        ([.group,.apim,.vnet] | all(.tags.purpose | eqi("apim-subnet-resize-poc"))) and
        (.group.id | eqi($root)) and (.vnet.id | eqi($vnet)) and
        (.apim.id | eqi($root + "/providers/Microsoft.ApiManagement/service/" + $apim)) and
        (.original.id | eqi($original)) and (.apim.sku.name | eqi("Developer")) and
        (.apim.virtualNetworkType | eqi("External")) and (.apim.additionalLocations | empty_items) and
        ([.apim,.vnet,.original] | all(.provisioningState | eqi("Succeeded"))) and
        (.apim.location | type == "string") and (.vnet.location | type == "string") and
        (.apim.location | gsub(" "; "") | length > 0) and
        ((.apim.location | gsub(" "; "") | ascii_downcase) == (.vnet.location | gsub(" "; "") | ascii_downcase)) and
        (.vnet.addressSpace.addressPrefixes == ["10.90.0.0/16"]) and
        (([.vnet.subnets[].id | ascii_downcase] | sort) == ($ids | map(ascii_downcase) | sort)) and
        (.vnet.virtualNetworkPeerings | empty_items) and
        (.original.addressPrefix == "10.90.0.0/27" or .original.addressPrefix == "10.90.0.0/26") and
        (.original | subnet_ok) and
        (if $allow and .temporary != null then
            (.temporary.id | eqi($temporary)) and (.temporary.addressPrefix == "10.90.1.0/27") and
            (.temporary.provisioningState | eqi("Succeeded")) and (.temporary | subnet_ok)
         else true end) and
        any($ids[]; ascii_downcase == ($s.apim.virtualNetworkConfiguration.subnetResourceId | ascii_downcase))
    ' <<< "$state" >/dev/null || { fail 'Resource state differs from the isolated Developer External lab. Refusing operation.'; return 1; }
}

has_allocations() {
    jq -e '[.ipConfigurations,.privateEndpoints,.ipConfigurationProfiles,.serviceAssociationLinks,
        .resourceNavigationLinks,.applicationGatewayIPConfigurations] | any(. != null and . != [])' <<< "$1" >/dev/null
}

confirm_mutation() {
    local answer
    if [[ $WHAT_IF == true ]]; then log "WhatIf: $1"; return 1; fi
    if [[ $YES == true ]]; then return 0; fi
    printf '%s\nType yes to approve: ' "$1" >&2
    if IFS= read -r answer && [[ $answer == yes ]]; then return 0; fi
    log 'Skipped: confirmation declined or input unavailable.'
    return 1
}

validate_health_url() {
    [[ ${1,,} =~ ^https://apim-resize-poc-[a-z0-9-]+\.azure-api\.net(:443)?/subnet-poc/health$ &&
       $1 == */subnet-poc/health ]] ||
        { fail 'Use only the HTTPS mock endpoint of this lab in Azure public cloud.'; return 1; }
}

resolve_health_url() {
    if [[ $URL_SET != true ]]; then
        load_environment "$ENV_FILE" || return 1
        local name=${ENV_VALUES[APIM_NAME]:-}
        [[ $name =~ ^apim-resize-poc-[a-zA-Z0-9-]+$ ]] ||
            { fail 'Set a valid lab APIM_NAME or supply --url.'; return 1; }
        URL="https://$name.azure-api.net/subnet-poc/health"
    fi
    validate_health_url "$URL"
}

health_sample() {
    local url=$1 timeout=$2 body errors meta rc code latency error='' success=false timestamp
    validate_health_url "$url" || return 1
    body=$(mktemp "$RUN_DIRECTORY/http-body-XXXXXXXX") || return 1
    errors=$(mktemp "$RUN_DIRECTORY/http-error-XXXXXXXX") || { rm -f -- "$body"; return 1; }
    timestamp=$(utc_now)
    if meta=$(curl --disable --silent --show-error --proto '=https' --max-redirs 0 \
        --max-time "$timeout" --output "$body" --write-out '%{http_code}\n%{time_total}' "$url" 2>"$errors"); then
        rc=0
    else rc=$?; fi
    code=${meta%%$'\n'*}
    latency=${meta#*$'\n'}
    if [[ ! $code =~ ^[0-9]{3}$ || ! $latency =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        code=0 latency=0 error='Invalid curl status or timing output'
    elif (( rc != 0 )); then
        error="curl exit code $rc: $(<"$errors")"
    elif [[ $code != 200 ]]; then
        error="Unexpected HTTP status $code"
    elif jq -se 'length == 1 and .[0] == {"status":"ok","poc":"apim-subnet-resize"}' "$body" >/dev/null 2>"$errors"; then
        success=true
    else
        error="Unexpected JSON payload"
    fi
    rm -f -- "$body" "$errors" || return 1
    jq -n --arg timestamp "$timestamp" --arg code "$code" --arg latency "$latency" \
        --argjson success "$success" --arg error "$error" \
        '{timestampUtc:$timestamp,statusCode:($code|tonumber),success:$success,
          latencyMs:((($latency|tonumber)*100000|round)/100),error:$error}'
}

assert_mock_health() {
    local sample
    log "HTTP START: $1; timeout=30s" || return 1
    sample=$(health_sample "https://$APIM_NAME.azure-api.net/subnet-poc/health" 30) || return 1
    save_evidence "$1.json" "$sample" || return 1
    if ! jq -e '.success == true' <<< "$sample" >/dev/null; then
        fail "HTTP health check failed: $(jq -r '.error' <<< "$sample")"
        return 1
    fi
    log 'HTTP health verified: status=200 and exact mock payload.'
}
