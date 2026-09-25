#!/usr/bin/env bash

# Deliberately independent of operational defaults: tests never fall back to .env.
get_test_environment() {
    local file=${1:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/.env.test"}
    local line key value number=0
    if [[ ${file##*/} == .env || ${file##*\\} == .env ]]; then
        printf '%s\n' 'Offline tests must not load operational .env files.' >&2
        return 1
    fi
    if [[ ! -f $file ]]; then
        printf '%s\n' 'Test environment file not found. Copy .env.test.example to .env.test or use --test-env-file.' >&2
        return 1
    fi
    declare -gA TEST_ENV_VALUES=()
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line%$'\r'}
        if (( number == 1 )); then line=${line#$'\xef\xbb\xbf'}; fi
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            printf 'Invalid test configuration syntax at line %s.\n' "$number" >&2
            return 1
        fi
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case "$key" in
            AZURE_SUBSCRIPTION_ID|AZURE_RESOURCE_GROUP|APIM_NAME|AZURE_LOCATION) ;;
            *) printf '%s\n' 'Test configuration accepts only the four keys in .env.test.example.' >&2; return 1 ;;
        esac
        if [[ ${TEST_ENV_VALUES[$key]+present} ]]; then
            printf 'Duplicate test configuration key: %s\n' "$key" >&2
            return 1
        fi
        if [[ $value == \"* || $value == \'* ]]; then
            if (( ${#value} < 2 )) || [[ ${value: -1} != "${value:0:1}" ]]; then
                printf '%s\n' 'Unclosed test configuration quote.' >&2
                return 1
            fi
            value=${value:1:${#value}-2}
        fi
        TEST_ENV_VALUES[$key]=$value
    done < "$file"
    for key in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP APIM_NAME AZURE_LOCATION; do
        if [[ ! ${TEST_ENV_VALUES[$key]:-} =~ [^[:space:]] ]]; then
            printf 'Missing %s in test configuration.\n' "$key" >&2
            return 1
        fi
    done
    TEST_SUBSCRIPTION_ID=${TEST_ENV_VALUES[AZURE_SUBSCRIPTION_ID]}
    TEST_RESOURCE_GROUP=${TEST_ENV_VALUES[AZURE_RESOURCE_GROUP]}
    TEST_APIM_NAME=${TEST_ENV_VALUES[APIM_NAME]}
    TEST_LOCATION=${TEST_ENV_VALUES[AZURE_LOCATION]}
    if [[ ! $TEST_SUBSCRIPTION_ID =~ ^00000000-0000-0000-0000-[0-9a-f]{12}$ ||
        $TEST_SUBSCRIPTION_ID == 00000000-0000-0000-0000-000000000000 ||
        ! $TEST_RESOURCE_GROUP =~ ^rg-apim-resize-poc-test(-[a-zA-Z0-9-]+)?$ ||
        ! $TEST_APIM_NAME =~ ^apim-resize-poc-test(-[a-zA-Z0-9-]+)?$ ]]; then
        printf '%s\n' 'Use synthetic test identifiers: a reserved nonzero GUID and test name prefixes.' >&2
        return 1
    fi
    if [[ ! $TEST_LOCATION =~ ^[a-z][a-z0-9]+$ ]]; then
        printf '%s\n' 'AZURE_LOCATION must be a canonical lowercase region name.' >&2
        return 1
    fi
}
