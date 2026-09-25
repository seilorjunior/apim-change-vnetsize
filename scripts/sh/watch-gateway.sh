#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${1:-} == --help && $# == 1 ]]; then
    cat <<'HELP'
Usage: bash scripts/sh/watch-gateway.sh [options]
  --url URL                      Override the configured lab HTTPS health URL
  --env-file PATH                Default: project-root .env (literal data)
  --duration-minutes N           1..1440; default: 180
  --interval-seconds N           1..60; default: 5
  --request-timeout-seconds N    1..120; default: 10
  --output-root PATH             Default: project-root artifacts
  --help                         Show this help without HTTP requests
Records sampled HTTP status, exact mock payload success, and latency in UTC.
Redirects are not followed. Sampled success is not an SLA or exact downtime.
HELP
    exit 0
fi
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
parse_options "$@"
require_commands jq curl
resolve_health_url
new_run_directory probe
csv="$RUN_DIRECTORY/samples.csv"
samples="$RUN_DIRECTORY/samples.jsonl"
printf '"timestampUtc","statusCode","success","latencyMs","error"\n' > "$csv"
: > "$samples"

finish() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -s $samples ]]; then
        if jq -s '
            [.[] | select(.success == true)] as $ok |
            ($ok | map(.latencyMs) | sort) as $latencies |
            {samples:length,successfulSamples:($ok|length),failedSamples:(length-($ok|length)),
             successPercent:((100000*($ok|length)/length|round)/1000),
             successfulLatencyP95Ms:(if ($ok|length)>0 then $latencies[((($ok|length)*0.95|ceil)-1)] else null end),
             limitation:"Sampled gateway mock only; not an SLA, exact downtime, private-backend test or Premium availability result."}
        ' "$samples" > "$RUN_DIRECTORY/summary.json"; then
            cat "$RUN_DIRECTORY/summary.json"
        else
            log 'Could not summarize probe samples.' ERROR
            rc=1
        fi
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
deadline=$((SECONDS + DURATION_MINUTES * 60))
log "Monitoring $URL. CSV: $csv. Keep this terminal open during network changes."
while :; do
    sample=$(health_sample "$URL" "$REQUEST_TIMEOUT_SECONDS")
    printf '%s\n' "$sample" | jq -c '.' >> "$samples"
    printf '%s\n' "$sample" | jq -r '[.timestampUtc,.statusCode,.success,.latencyMs,.error] | @csv' >> "$csv"
    if ! jq -e '.success' <<< "$sample" >/dev/null; then
        log "$(jq -r '.timestampUtc + ": " + .error' <<< "$sample")" WARN
    fi
    sleep "$INTERVAL_SECONDS"
    (( SECONDS < deadline )) || break
done
