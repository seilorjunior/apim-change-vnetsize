#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY=$(cd -- "$TEST_DIRECTORY/../.." && pwd)

# These subprocess doubles never fall through to installed Azure/HTTP clients.
mock_az() {
    local command="$*" name='' subscription='' group='' target='' stage='' arg previous=''
    printf 'az %s\n' "$command" >> "$CASE/events"
    printf '%s\n' "$command" >> "$CASE/az.calls"
    for arg in "$@"; do
        case "$previous" in
            --name) name=$arg ;;
            --subscription) subscription=$arg ;;
            --resource-group) group=$arg ;;
        esac
        [[ $arg != virtualNetworkConfiguration.subnetResourceId=* ]] || target=${arg#*=}
        previous=$arg
    done
    [[ $subscription == "$TEST_SUBSCRIPTION_ID" ]] || { echo 'Mock: missing explicit subscription' >&2; return 91; }
    if [[ $command == 'group show '* ]]; then group=$name; fi
    [[ $group == "$TEST_RESOURCE_GROUP" ]] || { echo 'Mock: missing explicit group' >&2; return 92; }
    if [[ $command == 'apim '* ]]; then
        [[ $name == "$TEST_APIM_NAME" ]] || { echo 'Mock: unexpected APIM name' >&2; return 93; }
    fi
    case "${FAULT:-}" in
        cli-failure) echo 'SimulatedCliFailure' >&2; return 23 ;;
        invalid-json) printf 'not JSON\n'; return ;;
        null-json) printf 'null\n'; return ;;
        empty-json) return ;;
    esac
    case "$command" in
        'group show '*) jq '.group' "$CASE/state.json"; return ;;
        'apim show '*)
            if [[ -s $CASE/pending ]]; then
                local remaining
                remaining=$(cat "$CASE/polls")
                if (( remaining > 0 )); then
                    printf '%s\n' "$((remaining - 1))" > "$CASE/polls"
                else
                    target=$(cat "$CASE/pending")
                    jq --arg target "$target" '.apim.virtualNetworkConfiguration.subnetResourceId=$target | .apim.provisioningState="Succeeded"' "$CASE/state.json" > "$CASE/next.json"
                    mv "$CASE/next.json" "$CASE/state.json"
                    : > "$CASE/pending"
                fi
            fi
            jq '.apim' "$CASE/state.json"; return ;;
        'network vnet show '*) jq '.vnet' "$CASE/state.json"; return ;;
        'network vnet subnet show '*)
            case "$name" in
                snet-apim-original) jq '.original' "$CASE/state.json" ;;
                snet-apim-temporary) jq '.temporary' "$CASE/state.json" ;;
                *) echo 'Mock: unexpected subnet read' >&2; return 94 ;;
            esac
            return ;;
        'network vnet subnet create '*)
            stage=PrepareTemporary
            [[ $name == snet-apim-temporary && $command == *'--address-prefixes 10.90.1.0/27'* &&
                $command == *"--network-security-group $NSG_ID"* ]] || return 95 ;;
        'network vnet subnet update '*)
            stage=ResizeEmpty
            [[ ${FLOW:-migration} != direct ]] || stage=TryResizeOccupied
            [[ $name == snet-apim-original && $command == *'--address-prefixes 10.90.0.0/26'* ]] || return 95
            if [[ $stage == ResizeEmpty ]]; then
                jq -e --arg id "$TEMPORARY_ID" '
                    .apim.virtualNetworkConfiguration.subnetResourceId == $id and
                    ([.original.ipConfigurations, .original.privateEndpoints,
                      .original.ipConfigurationProfiles, .original.serviceAssociationLinks,
                      .original.resourceNavigationLinks, .original.applicationGatewayIPConfigurations]
                      | map(. // []) | flatten | length == 0)' "$CASE/state.json" >/dev/null || {
                    echo 'Mock: unsafe occupied subnet resize' >&2; return 96;
                }
            fi ;;
        'apim update '*)
            [[ $command == *'--virtual-network External'* && $command == *'--no-wait'* ]] || return 95
            case "$target" in
                "$TEMPORARY_ID") stage=MoveTemporary ;;
                "$ORIGINAL_ID") stage=MoveBack ;;
                *) return 95 ;;
            esac ;;
        *) echo "Mock: forbidden command: $command" >&2; return 97 ;;
    esac
    printf '%s\n' "$stage" >> "$CASE/mutations"
    printf 'mutation %s\n' "$stage" >> "$CASE/events"
    if [[ ${FAULT:-} == "$stage-reject" ]]; then
        echo "Simulated${stage}Rejected: SubnetInUse" >&2; return 24
    fi
    if [[ ${FAULT:-} == "$stage-noop" ]]; then
        [[ $stage == MoveTemporary || $stage == MoveBack ]] || printf '{}\n'
        return
    fi
    if [[ ${FAULT:-} == "$stage-empty" ]]; then return; fi
    case "$stage" in
        PrepareTemporary)
            jq --arg id "$TEMPORARY_ID" '
                .temporary={id:$id, name:"snet-apim-temporary",addressPrefix:"10.90.1.0/27",
                provisioningState:"Succeeded",networkSecurityGroup:.original.networkSecurityGroup,
                ipConfigurations:[]} |
                .vnet.subnets += [{id:$id,name:"snet-apim-temporary"}]' "$CASE/state.json" > "$CASE/next.json" ;;
        TryResizeOccupied|ResizeEmpty)
            jq '.original.addressPrefix="10.90.0.0/26"' "$CASE/state.json" > "$CASE/next.json" ;;
        MoveTemporary|MoveBack)
            if [[ ${FAULT:-} == move-failed ]]; then
                jq '.apim.provisioningState="Failed"' "$CASE/state.json" > "$CASE/next.json"
            elif [[ ${FAULT:-} == wrong-target ]]; then
                cp "$CASE/state.json" "$CASE/next.json"
            else
                printf '%s\n' "$target" > "$CASE/pending"
                printf '%s\n' "${DELAY_POLLS:-0}" > "$CASE/polls"
                jq --arg target "$target" --arg original "$ORIGINAL_ID" --arg fault "${FAULT:-}" '
                    .apim.provisioningState="Updating" |
                    if $target == $original then
                        .original.ipConfigurations=[{id:"managed-apim-nic/ipconfig"}] |
                        .temporary.ipConfigurations=[]
                    else
                        .temporary.ipConfigurations=[{id:"managed-apim-nic/ipconfig"}] |
                        if $fault == "stale-allocations" then . else .original.ipConfigurations=[] end
                    end' "$CASE/state.json" > "$CASE/next.json"
            fi ;;
    esac
    mv "$CASE/next.json" "$CASE/state.json"
    case "$stage" in
        MoveTemporary|MoveBack)
            [[ ${FAULT:-} != move-literal-null ]] || printf 'null\n'
            return ;; # --no-wait legitimately returns either empty output or JSON null.
        PrepareTemporary) jq '.temporary' "$CASE/state.json" ;;
        *) jq '.original' "$CASE/state.json" ;;
    esac
}

mock_curl() {
    local output='' format='' url='' previous='' arg count status=200 latency=0.010
    printf 'curl %s\n' "$*" >> "$CASE/events"
    printf '%s\n' "$*" >> "$CASE/curl.calls"
    for arg in "$@"; do
        case "$previous" in
            --output|-o) output=$arg ;;
            --write-out|-w) format=$arg ;;
        esac
        [[ $arg != https://* && $arg != http://* ]] || url=$arg
        [[ $arg != --location && $arg != -L ]] || { echo 'Redirect following forbidden' >&2; return 98; }
        previous=$arg
    done
    [[ $url == "https://$TEST_APIM_NAME.azure-api.net/subnet-poc/health" ]] || {
        echo 'Mock: forbidden HTTP endpoint' >&2; return 98;
    }
    count=$(wc -l < "$CASE/curl.calls")
    local body=${HTTP_BODY:-'{"status":"ok","poc":"apim-subnet-resize"}'}
    status=${HTTP_STATUS:-200}
    if [[ ${FAULT:-} == health-after-move && $count == 4 ]]; then return 28; fi
    if [[ ${FAULT:-} == http-timeout ]]; then return 28; fi
    if [[ ${MONITOR_SEQUENCE:-false} == true ]]; then
        case "$count" in
            1) latency=0.010 ;;
            2) latency=0.020 ;;
            *) latency=0.999; status=503 ;;
        esac
    fi
    if [[ -n $output ]]; then printf '%s' "$body" > "$output"; else printf '%s' "$body"; fi
    format=${format//'%{http_code}'/$status}
    format=${format//'%{response_code}'/$status}
    format=${format//'%{time_total}'/$latency}
    format=${format//'%{url_effective}'/$url}
    format=${format//'%{num_redirects}'/0}
    printf '%b' "$format"
}

mock_sleep() {
    if [[ ${MONITOR_TEST:-false} != true ]]; then /bin/sleep "$@"; return; fi
    local count
    count=$(wc -l < "$CASE/curl.calls")
    if (( count >= ${MONITOR_SAMPLES:-1} )); then
        # PPID is the monitor owned by this test, not a process-name match.
        [[ -f $CASE/monitor.pid && $(cat "$CASE/monitor.pid") == "$PPID" ]] || return 99
        kill -TERM "$PPID"
    fi
}

if [[ ${1:-} == --internal-mock ]]; then
    kind=$2; shift 2
    case "$kind" in az) mock_az "$@" ;; curl) mock_curl "$@" ;; sleep) mock_sleep "$@" ;; *) exit 99 ;; esac
    exit
fi

usage() {
    printf '%s\n' 'Usage: bash tests/sh/test-bash.sh [--test-env-file FILE]' \
        'Offline public CLI tests. Defaults only to repository .env.test; never .env.'
}
TEST_ENV_FILE="$REPOSITORY/.env.test"
while (( $# )); do
    case "$1" in
        --help) usage; exit 0 ;;
        --test-env-file) (( $# >= 2 )) || { usage >&2; exit 2; }; TEST_ENV_FILE=$2; shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
source "$TEST_DIRECTORY/common.sh"
get_test_environment "$TEST_ENV_FILE"
for dependency in bash jq; do command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; exit 1; }; done
TEST_ROOT="$REPOSITORY/artifacts/bash-tests-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
mkdir -p "$TEST_ROOT/bin"
TEST_BASH=$(command -v bash)
export TEST_SUBSCRIPTION_ID TEST_RESOURCE_GROUP TEST_APIM_NAME TEST_LOCATION
ROOT_ID="/subscriptions/$TEST_SUBSCRIPTION_ID/resourceGroups/$TEST_RESOURCE_GROUP"
VNET_ID="$ROOT_ID/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
export ORIGINAL_ID="$VNET_ID/subnets/snet-apim-original"
export TEMPORARY_ID="$VNET_ID/subnets/snet-apim-temporary"
export NSG_ID="$ROOT_ID/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-resize-poc"
export TEST_ENTRY="$TEST_DIRECTORY/test-bash.sh"
export TEST_BASH
for mock in az curl sleep; do
    printf '#!/usr/bin/env bash\nexec "$TEST_BASH" "$TEST_ENTRY" --internal-mock %s "$@"\n' "$mock" > "$TEST_ROOT/bin/$mock"
    chmod +x "$TEST_ROOT/bin/$mock"
done
export PATH="$TEST_ROOT/bin:$PATH"
jq -n --arg root "$ROOT_ID" --arg vnet "$VNET_ID" --arg original "$ORIGINAL_ID" \
    --arg nsg "$NSG_ID" --arg name "$TEST_APIM_NAME" --arg location "$TEST_LOCATION" '
    {purpose:"apim-subnet-resize-poc",environment:"lab"} as $tags |
    {group:{id:$root,tags:$tags},
     apim:{id:($root+"/providers/Microsoft.ApiManagement/service/"+$name),tags:$tags,
       sku:{name:"Developer",capacity:1},platformVersion:"stv2",location:$location,
       virtualNetworkType:"External",provisioningState:"Succeeded",
       virtualNetworkConfiguration:{subnetResourceId:$original}},
     vnet:{id:$vnet,tags:$tags,location:$location,provisioningState:"Succeeded",
       addressSpace:{addressPrefixes:["10.90.0.0/16"]},dhcpOptions:{dnsServers:[]},
       subnets:[{id:$original,name:"snet-apim-original"}],virtualNetworkPeerings:[]},
     original:{id:$original,name:"snet-apim-original",addressPrefix:"10.90.0.0/27",
       provisioningState:"Succeeded",networkSecurityGroup:{id:$nsg},
       ipConfigurations:[{id:"managed-apim-nic/ipconfig"}]},temporary:null}' > "$TEST_ROOT/pristine.json"
printf 'AZURE_SUBSCRIPTION_ID=%s\nAZURE_RESOURCE_GROUP=%s\nAPIM_NAME=%s\nAZURE_LOCATION=%s\n' \
    "$TEST_SUBSCRIPTION_ID" "$TEST_RESOURCE_GROUP" "$TEST_APIM_NAME" "$TEST_LOCATION" > "$TEST_ROOT/synthetic.env"

PASSED=0 FAILED=0 CASE_NUMBER=0
assert() {
    local message=$1; shift
    if "$@"; then PASSED=$((PASSED + 1)); else
        FAILED=$((FAILED + 1)); printf 'FAIL [%s]: %s\n' "${CASE##*/}" "$message" >&2
    fi
}
new_case() {
    CASE_NUMBER=$((CASE_NUMBER + 1))
    export CASE="$TEST_ROOT/$(printf '%03d' "$CASE_NUMBER")-$1"
    mkdir -p "$CASE"
    cp "$TEST_ROOT/pristine.json" "$CASE/state.json"
    : > "$CASE/az.calls"; : > "$CASE/curl.calls"; : > "$CASE/mutations"; : > "$CASE/events"
    export FAULT='' FLOW=migration DELAY_POLLS=0 HTTP_STATUS=200
    export HTTP_BODY='{"status":"ok","poc":"apim-subnet-resize"}'
    export MONITOR_TEST=false MONITOR_SEQUENCE=false MONITOR_SAMPLES=1
    REPORT=''
}
edit_state() {
    jq --arg temporary "$TEMPORARY_ID" --arg original "$ORIGINAL_ID" "$1" "$CASE/state.json" > "$CASE/edited.json"
    mv "$CASE/edited.json" "$CASE/state.json"
}
temporary_state() {
    edit_state '.temporary={id:$temporary,name:"snet-apim-temporary",addressPrefix:"10.90.1.0/27",
      provisioningState:"Succeeded",networkSecurityGroup:.original.networkSecurityGroup,ipConfigurations:[]} |
      .vnet.subnets += [{id:$temporary,name:"snet-apim-temporary"}]'
}
on_temporary() {
    temporary_state
    edit_state '.apim.virtualNetworkConfiguration.subnetResourceId=$temporary |
        .original.ipConfigurations=[] | .temporary.ipConfigurations=[{id:"managed-apim-nic/ipconfig"}]'
}
run_cli() {
    local script=$1; shift
    local argument has_env=false
    local -a defaults=()
    for argument in "$@"; do [[ $argument != --env-file ]] || has_env=true; done
    [[ $has_env == true ]] || defaults=(--env-file "$TEST_ROOT/synthetic.env")
    STATUS=0
    "$TEST_BASH" "$REPOSITORY/scripts/sh/$script" "${defaults[@]}" \
        --output-root "$CASE/evidence" "$@" < /dev/null > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
    REPORT=$(find "$CASE/evidence" -name result.json -type f 2>/dev/null | head -n 1) || true
}
mutations_are() {
    [[ $(paste -sd, "$CASE/mutations") == "$1" ]]
}
report_is() {
    [[ -n $REPORT ]] && jq -e "$1" "$REPORT" >/dev/null
}
summary_is() {
    [[ -n ${SUMMARY:-} && -s $SUMMARY ]] && jq -e "$1" "$SUMMARY" >/dev/null
}
stages_are_guarded() {
    awk '
        /^az group show / { reads++ }
        /^curl / { probes++ }
        /^mutation / {
            if (reads < 1 || probes < 1) invalid=1
            reads=0; probes=0; mutations++
        }
        END { exit (invalid || mutations != 4 || probes != 1 || reads < 1) }
    ' "$CASE/events"
}
expect_failure() {
    assert 'command rejects unsafe input/state' test "$STATUS" -ne 0
    assert 'no unexpected mutation' mutations_are "${1:-}"
}
migration() {
    local argument timeout=false poll=false
    local -a defaults=()
    for argument in "$@"; do
        [[ $argument != --timeout-seconds ]] || timeout=true
        [[ $argument != --poll-seconds ]] || poll=true
    done
    [[ $timeout == true ]] || defaults+=(--timeout-seconds 1)
    [[ $poll == true ]] || defaults+=(--poll-seconds 1)
    run_cli invoke-subnet-migration.sh "${defaults[@]}" "$@"
}
experiment() {
    FLOW=direct
    run_cli invoke-subnet-experiment.sh "$@"
}

# Relocated scripts must still resolve configuration and evidence at the root.
new_case nested-layout
project="$CASE/project"
mkdir -p "$project/scripts/sh" "$project/tests/sh"
cp "$REPOSITORY"/scripts/sh/*.sh "$project/scripts/sh/"
cp "$TEST_DIRECTORY/common.sh" "$project/tests/sh/"
cp "$TEST_ROOT/synthetic.env" "$project/.env"
cp "$TEST_ROOT/synthetic.env" "$project/.env.test"
assert 'nested test helper loads root test configuration' "$TEST_BASH" -c \
    'cd /; source "$1/tests/sh/common.sh"; get_test_environment' _ "$project"
rm -- "$project/.env.test"
assert 'nested test helper never falls back to operational config' "$TEST_BASH" -c \
    'cd /; source "$1/tests/sh/common.sh"; ! get_test_environment' _ "$project"
assert 'nested monitor resolves root environment and evidence defaults' "$TEST_BASH" -c \
    'cd /; source "$1/scripts/sh/common.sh"; parse_options; resolve_health_url &&
     [[ $URL == "https://$TEST_APIM_NAME.azure-api.net/subnet-poc/health" &&
        $OUTPUT_ROOT == "$1/artifacts" ]]' _ "$project"
for script in invoke-subnet-experiment.sh invoke-subnet-migration.sh; do
    STATUS=0
    (cd "$project/scripts/sh"; "$TEST_BASH" "./$script") \
        > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
    assert 'nested snapshot resolves root environment without explicit flags' test "$STATUS" -eq 0
done
assert 'both snapshots save evidence at project root' test "$(find "$project/artifacts" -name result.json | wc -l)" -eq 2
assert 'nested snapshots never mutate' mutations_are ''
assert 'no evidence inside scripts' test ! -e "$project/scripts/artifacts"

# Loader validation is isolated from both real environment files.
new_case test-loader
assert 'synthetic configuration loads' get_test_environment "$TEST_ROOT/synthetic.env"
assert 'operational basename rejected before reading' bash -c 'source "$1"; ! get_test_environment "$2"' _ "$TEST_DIRECTORY/common.sh" "$REPOSITORY/.env"
assert 'missing test file does not fall back' bash -c 'source "$1"; ! get_test_environment "$2"' _ "$TEST_DIRECTORY/common.sh" "$TEST_ROOT/missing"
for key in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP APIM_NAME AZURE_LOCATION; do
    grep -v "^$key=" "$TEST_ROOT/synthetic.env" > "$CASE/invalid.env"
    assert "missing $key rejected" bash -c 'source "$1"; ! get_test_environment "$2"' _ "$TEST_DIRECTORY/common.sh" "$CASE/invalid.env"
done
for replacement in \
    'AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111' \
    'AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000' \
    'AZURE_RESOURCE_GROUP=rg-apim-resize-poc-live' 'APIM_NAME=apim-resize-poc-live' \
    'AZURE_LOCATION=East US 2' 'APIM_NAME=' 'APIM_NAME="unclosed'; do
    key=${replacement%%=*}
    grep -v "^$key=" "$TEST_ROOT/synthetic.env" > "$CASE/invalid.env"
    printf '%s\n' "$replacement" >> "$CASE/invalid.env"
    assert "invalid $key rejected" bash -c 'source "$1"; ! get_test_environment "$2"' _ "$TEST_DIRECTORY/common.sh" "$CASE/invalid.env"
done
for extra in 'AZURE_TENANT_ID=00000000-0000-0000-0000-000000000002' 'APIM_NAME=duplicate' 'export APIM_NAME=test' 'apim_name=test'; do
    cat "$TEST_ROOT/synthetic.env" > "$CASE/invalid.env"; printf '%s\n' "$extra" >> "$CASE/invalid.env"
    assert 'unknown, duplicate, or executable syntax rejected' bash -c 'source "$1"; ! get_test_environment "$2"' _ "$TEST_DIRECTORY/common.sh" "$CASE/invalid.env"
done

for script in invoke-subnet-experiment.sh invoke-subnet-migration.sh watch-gateway.sh; do
    new_case "help-$script"
    mkdir -p "$CASE/core-tools"
    for core in cat dirname; do ln -s "$(command -v "$core")" "$CASE/core-tools/$core"; done
    STATUS=0
    PATH="$CASE/core-tools" "$TEST_BASH" "$REPOSITORY/scripts/sh/$script" --help > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
    assert 'help needs no az, curl, jq, or environment' test "$STATUS" -eq 0
done

for script in invoke-subnet-experiment.sh invoke-subnet-migration.sh; do
    new_case "default-$script"
    run_cli "$script"
    assert 'default action succeeds' test "$STATUS" -eq 0
    assert 'default action is read only' mutations_are ''
    assert 'default stdout is a snapshot object' jq -e '.original.addressPrefix=="10.90.0.0/27"' "$CASE/stdout"
    for option in --subscription-id --resource-group --apim-name; do
        new_case "empty-$option-$script"
        run_cli "$script" "$option" ''
        expect_failure
        assert 'invalid explicit target makes no CLI calls' test ! -s "$CASE/az.calls"
    done
    new_case "explicit-$script"
    run_cli "$script" --env-file "$TEST_ROOT/does-not-exist" --subscription-id "$TEST_SUBSCRIPTION_ID" \
        --resource-group "$TEST_RESOURCE_GROUP" --apim-name "$TEST_APIM_NAME"
    assert 'complete explicit target bypasses missing file' test "$STATUS" -eq 0
    new_case "precedence-$script"
    sed "s/APIM_NAME=.*/APIM_NAME=$TEST_APIM_NAME-other/" "$TEST_ROOT/synthetic.env" > "$CASE/other.env"
    run_cli "$script" --env-file "$CASE/other.env" --apim-name "$TEST_APIM_NAME"
    assert 'explicit name overrides only its file value' test "$STATUS" -eq 0
    for fault in cli-failure empty-json invalid-json null-json; do
        new_case "$fault-$script"; FAULT=$fault
        run_cli "$script"
        expect_failure
    done
done

new_case literal-environment
cat "$TEST_ROOT/synthetic.env" > "$CASE/literal.env"
printf 'AZURE_SUBSCRIPTION_NAME="literal $(touch %s/injected) `touch %s/backtick` $HOME # = text"\n' "$CASE" "$CASE" >> "$CASE/literal.env"
experiment --env-file "$CASE/literal.env"
assert 'quoted operational metadata is literal' test "$STATUS" -eq 0
assert 'command substitution was not evaluated' test ! -e "$CASE/injected"
assert 'backticks were not evaluated' test ! -e "$CASE/backtick"

for mode in direct migration; do
    for reason in premium internal untagged cross-group updating region missing-region peering delegation route prefix extra-subnet disconnected nsg; do
        new_case "guard-$mode-$reason"
        case "$reason" in
            premium) edit_state '.apim.sku.name="Premium"' ;;
            internal) edit_state '.apim.virtualNetworkType="Internal"' ;;
            untagged) edit_state '.group.tags.purpose="production"' ;;
            cross-group) edit_state '.original.id="/another/subnet"' ;;
            updating) edit_state '.apim.provisioningState="Updating"' ;;
            region) edit_state '.apim.location="differentregion"' ;;
            missing-region) edit_state 'del(.apim.location)' ;;
            peering) edit_state '.vnet.virtualNetworkPeerings=[{id:"peer"}]' ;;
            delegation) edit_state '.original.delegations=[{name:"delegated"}]' ;;
            route) edit_state '.original.routeTable={id:"route"}' ;;
            prefix) edit_state '.original.addressPrefix="10.90.0.0/25"' ;;
            extra-subnet) edit_state '.vnet.subnets += [{id:"unexpected"}]' ;;
            disconnected) edit_state '.apim.virtualNetworkConfiguration.subnetResourceId=null' ;;
            nsg) edit_state '.original.networkSecurityGroup.id="other"' ;;
        esac
        if [[ $mode == direct ]]; then experiment --action TryResizeOccupied --yes; else migration --action Run --yes; fi
        expect_failure
    done
    for approval in what-if decline; do
        new_case "$mode-$approval"
        args=(); [[ $approval != what-if ]] || args=(--what-if --yes)
        if [[ $mode == direct ]]; then experiment --action TryResizeOccupied "${args[@]}"; else migration --action Run "${args[@]}"; fi
        assert 'unapproved action completes as skipped' test "$STATUS" -eq 0
        assert 'unapproved action never mutates' mutations_are ''
        assert 'skipped result is durable' report_is '.outcome=="Skipped"'
        assert 'unapproved action does not probe HTTP' test ! -s "$CASE/curl.calls"
    done
done

for fault in '' TryResizeOccupied-reject TryResizeOccupied-noop TryResizeOccupied-empty; do
    new_case "direct-${fault:-success}"; FAULT=$fault
    experiment --action TryResizeOccupied --yes
    assert 'direct action submits only one resize' mutations_are TryResizeOccupied
    if [[ -z $fault ]]; then
        assert 'accepted direct resize succeeds' test "$STATUS" -eq 0
        assert 'verified control plane outcome' report_is '.outcome=="ControlPlaneSucceeded"'
        assert 'APIM remains on expanded original subnet' jq -e --arg original "$ORIGINAL_ID" \
            '.original.addressPrefix=="10.90.0.0/26" and .apim.virtualNetworkConfiguration.subnetResourceId==$original' "$CASE/state.json"
    else
        assert 'rejection or failed postcondition fails' test "$STATUS" -ne 0
        assert 'failure cannot claim control plane success' report_is '.outcome=="FailedOrRejected"'
        assert 'failure captures fresh state' test -f "$(dirname "$REPORT")/after-error.json"
    fi
done

new_case migration-success
migration --action Run --yes
assert 'full migration succeeds' test "$STATUS" -eq 0
assert 'exactly four ordered mutations' mutations_are 'PrepareTemporary,MoveTemporary,ResizeEmpty,MoveBack'
assert 'all stages verified on control and data planes' report_is '.outcome=="Verified" and (.completedStages|length)==4 and (.controlPlaneVerifiedStages|length)==4'
assert 'eight health guards surround four stages' test "$(wc -l < "$CASE/curl.calls")" -eq 8
assert 'fresh reads and health guards occur between mutations' stages_are_guarded
assert 'original /26 restored and temporary retained' jq -e --arg original "$ORIGINAL_ID" \
    '.original.addressPrefix=="10.90.0.0/26" and .temporary!=null and .apim.virtualNetworkConfiguration.subnetResourceId==$original' "$CASE/state.json"
for stage in PrepareTemporary MoveTemporary ResizeEmpty MoveBack; do
    for suffix in before after response http-before http-after; do
        assert "$stage fresh $suffix evidence" test -f "$(dirname "$REPORT")/$stage-$suffix.json"
    done
done
assert 'empty asynchronous submission preserved as null' jq -e '.==null' "$(dirname "$REPORT")/MoveTemporary-response.json"
assert 'resize has immediately verified empty snapshot' jq -e '(.original.ipConfigurations|length)==0' "$(dirname "$REPORT")/ResizeEmpty-verified-empty.json"

new_case migration-literal-null-submission
temporary_state
FAULT=move-literal-null
migration --action MoveTemporary --yes
assert 'literal null asynchronous submission is accepted' test "$STATUS" -eq 0
assert 'literal null submission never causes retries' mutations_are MoveTemporary
assert 'literal null response is preserved' jq -e '.==null' "$(dirname "$REPORT")/MoveTemporary-response.json"
assert 'literal null submission still requires verified completion' report_is \
    '.outcome=="Verified" and .completedStages==["MoveTemporary"] and .controlPlaneVerifiedStages==["MoveTemporary"]'

new_case migration-readonly-updating
edit_state '.apim.provisioningState="Updating"'
migration
assert 'snapshot remains available during an operation' test "$STATUS" -eq 0
assert 'diagnostic snapshot cannot mutate' mutations_are ''
assert 'diagnostic snapshot preserves actual pending state' jq -e '.apim.provisioningState=="Updating"' "$CASE/stdout"

new_case migration-default-dns
edit_state '.vnet.dhcpOptions=null'
migration --action PrepareTemporary --yes
assert 'null DNS means default DNS and is supported' test "$STATUS" -eq 0
assert 'default DNS permits only requested prepare' mutations_are PrepareTemporary

for stage in PrepareTemporary MoveTemporary ResizeEmpty MoveBack; do
    new_case "individual-$stage"
    case "$stage" in
        MoveTemporary) temporary_state; DELAY_POLLS=1 ;;
        ResizeEmpty) on_temporary ;;
        MoveBack) on_temporary; edit_state '.original.addressPrefix="10.90.0.0/26"' ;;
    esac
    migration --action "$stage" --yes --timeout-seconds 4
    assert 'individual stage succeeds' test "$STATUS" -eq 0
    assert 'individual stage issues only requested mutation' mutations_are "$stage"
done

for fault in PrepareTemporary-reject PrepareTemporary-noop PrepareTemporary-empty MoveTemporary-reject \
    MoveTemporary-noop move-failed wrong-target ResizeEmpty-reject ResizeEmpty-noop ResizeEmpty-empty \
    MoveBack-reject health-after-move stale-allocations; do
    new_case "migration-$fault"; FAULT=$fault
    migration --action Run --yes
    expected='PrepareTemporary,MoveTemporary'
    case "$fault" in
        PrepareTemporary-*) expected=PrepareTemporary ;;
        ResizeEmpty-*) expected+=,ResizeEmpty ;;
        MoveBack-*) expected+=,ResizeEmpty,MoveBack ;;
    esac
    expect_failure "$expected"
    assert 'failed migration has durable failed result' report_is '.outcome=="Failed" and (.error|length)>0'
    if [[ $fault == health-after-move ]]; then
        assert 'health failure retains partial control-plane verification' report_is \
            '(.controlPlaneVerifiedStages|length)==2 and (.completedStages|length)==1'
    fi
done

for field in ipConfigurations privateEndpoints ipConfigurationProfiles serviceAssociationLinks resourceNavigationLinks applicationGatewayIPConfigurations; do
    new_case "allocation-$field"; on_temporary
    edit_state ".original.$field=[{id:\"occupied\"}]"
    migration --action ResizeEmpty --yes
    expect_failure
done
for guard in capacity dns environment existing-temporary temporary-nsg temporary-route occupied-temporary unsafe-resize unsafe-return; do
    new_case "migration-guard-$guard"; action=Run
    case "$guard" in
        capacity) edit_state '.apim.sku.capacity=2' ;;
        dns) edit_state '.vnet.dhcpOptions.dnsServers=["10.90.2.4"]' ;;
        environment) edit_state '.group.tags.environment="production"' ;;
        existing-temporary) temporary_state ;;
        temporary-nsg) temporary_state; edit_state '.temporary.networkSecurityGroup.id="wrong"'; action=MoveTemporary ;;
        temporary-route) temporary_state; edit_state '.temporary.routeTable={id:"route"}'; action=MoveTemporary ;;
        occupied-temporary) temporary_state; edit_state '.temporary.privateEndpoints=[{id:"pe"}]'; action=MoveTemporary ;;
        unsafe-resize) temporary_state; action=ResizeEmpty ;;
        unsafe-return) on_temporary; action=MoveBack ;;
    esac
    migration --action "$action" --yes
    expect_failure
done

for body in '{"status":"bad","poc":"apim-subnet-resize"}' '{"status":"ok","poc":"apim-subnet-resize","extra":1}' '[]' 'not json'; do
    new_case strict-migration-payload; HTTP_BODY=$body
    migration --action PrepareTemporary --yes
    expect_failure
done
for status in 302 503; do
    new_case "migration-http-$status"; HTTP_STATUS=$status
    migration --action PrepareTemporary --yes
    expect_failure
done
for option in --timeout-seconds --poll-seconds; do
    for value in 0 -1 abc 14401; do
        new_case "range-$option-$value"
        migration "$option" "$value"
        expect_failure
        assert 'invalid range performs no Azure calls' test ! -s "$CASE/az.calls"
    done
done

for url in '' '/subnet-poc/health' 'http://example.com/' 'https://example.com/subnet-poc/health' \
    "https://$TEST_APIM_NAME.azure-api.net/subnet-poc/health?query=1" \
    "https://$TEST_APIM_NAME.azure-api.net/subnet-poc/health#fragment" \
    "https://user@$TEST_APIM_NAME.azure-api.net/subnet-poc/health"; do
    new_case invalid-monitor-url
    run_cli watch-gateway.sh --url "$url"
    expect_failure
    assert 'invalid monitor endpoint makes no HTTP calls' test ! -s "$CASE/curl.calls"
    assert 'invalid endpoint creates no evidence' test ! -e "$CASE/evidence"
done
for option in --duration-minutes --interval-seconds --request-timeout-seconds; do
    for value in 0 -1 abc 1441; do
        new_case "monitor-range-$option-$value"
        run_cli watch-gateway.sh "$option" "$value"
        expect_failure
        assert 'invalid range performs no HTTP calls' test ! -s "$CASE/curl.calls"
    done
done

run_monitor() {
    export MONITOR_TEST=true
    local argument has_env=false
    local -a defaults=()
    for argument in "$@"; do [[ $argument != --env-file ]] || has_env=true; done
    [[ $has_env == true ]] || defaults=(--env-file "$TEST_ROOT/synthetic.env")
    STATUS=0
    "$TEST_BASH" "$REPOSITORY/scripts/sh/watch-gateway.sh" "${defaults[@]}" \
        --output-root "$CASE/evidence" --duration-minutes 1 --interval-seconds 1 --request-timeout-seconds 1 \
        "$@" > "$CASE/stdout" 2> "$CASE/stderr" &
    local pid=$!
    printf '%s\n' "$pid" > "$CASE/monitor.pid"
    wait "$pid" || STATUS=$?
    SUMMARY=$(find "$CASE/evidence" -name summary.json -type f 2>/dev/null | head -n 1) || true
    CSV=$(find "$CASE/evidence" -name '*.csv' -type f 2>/dev/null | head -n 1) || true
}
new_case monitor-summary
MONITOR_SEQUENCE=true MONITOR_SAMPLES=3
run_monitor --url "https://$TEST_APIM_NAME.azure-api.net/subnet-poc/health" --env-file "$TEST_ROOT/missing"
assert 'monitor saves summary after owned-child termination' test -n "$SUMMARY"
assert 'CSV includes header and three samples' test "$(wc -l < "${CSV:-/dev/null}")" -eq 4
assert 'summary p95 excludes failures and uses successful latencies' summary_is \
    '.samples==3 and .failedSamples==1 and .successPercent==66.667 and .successfulLatencyP95Ms==20'
for fault in status payload timeout redirect; do
    new_case "monitor-$fault"
    case "$fault" in
        status) HTTP_STATUS=503 ;;
        payload) HTTP_BODY='{"status":"ok","poc":"apim-subnet-resize","extra":1}' ;;
        timeout) FAULT=http-timeout ;;
        redirect) HTTP_STATUS=302 ;;
    esac
    run_monitor
    assert 'invalid HTTP response is a failed sample' summary_is \
        '.samples==1 and .failedSamples==1 and .successPercent==0 and .successfulLatencyP95Ms==null'
done
printf '\n%s passed; %s failed. Azure CLI and HTTP were mocked. Local evidence: %s\n' "$PASSED" "$FAILED" "$TEST_ROOT"
(( FAILED == 0 ))
