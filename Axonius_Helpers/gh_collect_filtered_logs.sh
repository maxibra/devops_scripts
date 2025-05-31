#!/usr/bin/env bash

# Collect logs from GitHub Actions for the last X hours
# Usage: ./collect_logs.sh [hours]
# Example: ./collect_logs.sh 20
# If no argument is provided, it defaults to 20 hours
# This script collects logs from GitHub Actions for failed workflows in specified repositories.
# It uses the GitHub CLI to list the runs, filter them by failure status, and download the logs.
# It also greps for specific error messages in the logs and saves them to separate files.
# The script requires the GitHub CLI (gh) and jq to be installed and configured.
# Ensure you have the necessary permissions to access the repositories and download logs.
# The script creates a temporary directory to store the logs and cleans it up after execution.

generate_running_message_summary() {
    end_time=$(date -u +%s)
    runtime=$((end_time - start_time))
    hours=$((runtime / 3600))
    minutes=$(( (runtime % 3600) / 60 ))
    seconds=$((runtime % 60))
    human_readable=$(printf "%02dh:%02dm:%02ds" "$hours" "$minutes" "$seconds")
    end_rate_limit="$(gh api /rate_limit)"
    end_used_rate_limit_core="$(echo ${end_rate_limit} | jq '.resources.core.used')"
    end_used_rate_limit_graphql="$(echo ${end_rate_limit} | jq '.resources.graphql.used')"
    used_rate_limit_core=$((end_used_rate_limit_core - start_rate_limit_core))
    used_rate_limit_graphql=$((end_used_rate_limit_graphql - start_rate_limit_graphql))

    echo -e "\n==========================\n"
    echo "Total runtime: ${human_readable}"
    echo "Used rate limit (Core): ${used_rate_limit_core}"
    echo "Used rate limit (GraphQL): ${used_rate_limit_graphql}"
    echo "Remaining rate limit (Core): $(echo ${end_rate_limit} | jq '.resources.core.remaining')"
    echo "Remaining rate limit (GraphQL): $(echo ${end_rate_limit} | jq '.resources.graphql.remaining')"
    echo -e "\n==========================\n"
}

generate_metadata() {
    run_title=$(echo ${runs_failed_json} | jq -r ".[] | select(.databaseId == $run_id) | .displayTitle")
    actor=$(curl -s -L \
                    -H "Authorization: Bearer ${gh_token}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/repos/Axonius/${r}/actions/runs/${run_id}" | \
            jq -r '.actor.login')
    
    echo "${actor} - ${run_title}"
}

collect_run_logs() {
    run_failed_logs=$(gh run view "${run_id}" --repo "Axonius/${r}" --log-failed)
    if [ -n "${run_failed_logs}" ]; then
        echo -e "${run_metadata}\n" > "${log_file_prefix}_failed.log"
        echo "${run_failed_logs}" >> "${log_file_prefix}_failed.log"
    fi

    if [ ! -s "${log_file_prefix}_failed.log" ]; then
        echo -e "${run_metadata}\n" > "${log_file_prefix}_full.log"
        gh run view "${run_id}" --repo "Axonius/${r}" > "${log_file_prefix}_full.log"
    fi
}

collect_run_filtered_failures() {
    run_filtered_failures_log="${root_d}/${filtred_file_prefix}${r}_${run_id}.txt"
    filtered_failures=$(grep -sEi "${errors_pattern}" ${log_file_prefix}*)
    if [ -n "${filtered_failures}" ]; then
        echo -e "${run_metadata}\n" > "${run_filtered_failures_log}"
        echo "${filtered_failures}" >> "${run_filtered_failures_log}"
        run_metadata="X ${run_metadata}"
    else
        run_metadata="V ${run_metadata}"
    fi
}

# Check dependencies
if ! command -v gh >/dev/null; then
    echo "Error: gh CLI is required. Install from https://cli.github.com/" >&2
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "Error: jq is required. Install with 'brew install jq' or from https://stedolan.github.io/jq/" >&2
    exit 1
fi

back_hours="$1"
log_back_hours="${back_hours:=20}"
echo -e "\nCollecting logs for the last ${log_back_hours} hours...\n"
from_t=$(date -u -v-${log_back_hours}H +%s); 
root_d=/tmp/gha_workflows_logs
filtred_file_prefix="gh_run_grep_filtered_failures_"
run_log_prefix="gh_run_"
errors_pattern="ecr.*403 Forbidden|ERROR*buildx|ERROR*ecr|unauth|not authorize|Required property is missing: shell"
gh_token=$(gh auth token)
# Format: REPO:[runs_list_limit]
# Example: "cortex:100"
# This will limit the number of runs to 100 for the cortex repo
# The default limit is 10 for all other repos
repos=("ansible-playbooks:" "arsenal:" "atlas:" "atlas-operator:" "automatic-bug-tickets:" "axonius-artifacts-hub:" \
        "axonius-saas:" "central-api:" "crews-control:" "crews-control-internal:" "cortex:100" "data-enrichment:" \
        "dbt_analytics_sa:" "devex-test-repo:" "devops:" "gitops-test-app:" "naabu:" "openvpn_exporter:" "packer:50" \
        "product_analytics:" "product_analytics_library:" "ps-sec-actions-test:" "ps-tools:" "saas-monthly-cost-report:" \
        "sx:" "unified-ep-nginx:" "zgrab2:")

start_rate_limit_core="$(gh api /rate_limit --jq '.resources.core.used')"
start_rate_limit_graphql="$(gh api /rate_limit --jq '.resources.graphql.used')"
start_time=$(date -u +%s)
mkdir -p ${root_d}
if [ -n "$(find ${root_d} -type f)" ]; then 
    bck_dir="${root_d}_backup/$(date +'%Y_%m_%d-%H%M')"
    mkdir -p "${bck_dir}"
    mv ${root_d}/* "${bck_dir}/"
    echo "Moved existing logs to backup directory: ${bck_dir}"
fi

for r_l in "${repos[@]}"; do
    run_failed_logs_missing=true
    r=$(echo "${r_l}" | cut -d':' -f1)
    runs_limit=$(echo "${r_l}" | cut -d':' -f2)
    r_limit=${runs_limit:-10}
    echo "${r}: ${r_limit}"
    runs_failed_json=$(gh run list --repo "Axonius/${r}" --limit "${r_limit}" -s failure \
                            --json createdAt,databaseId,status,conclusion,name,displayTitle)
    echo "${runs_failed_json}" | jq '.' > "${root_d}/gha_failed_workflows_${r}.json"

    for run_id in $(echo "${runs_failed_json}" | jq '.[].databaseId'); do
        run_datetime=$(echo "${runs_failed_json}" | jq -r ".[] | select(.databaseId == $run_id) | .createdAt")
        run_timestamp=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "${run_datetime}" +%s)
        if [ "${run_timestamp}" -gt "${from_t}" ]; then
            run_failed_logs_missing=false
            run_metadata="${run_id}: ${run_datetime} - $(generate_metadata)"
            log_file_prefix="${root_d}/${run_log_prefix}${r}_${run_id}"

            collect_run_logs
            collect_run_filtered_failures
            echo -e "\t${run_metadata}"
        fi
    done
    if [ "${run_failed_logs_missing}" = true ]; then
        echo -e "\tNo failed logs were found in the last ${log_back_hours} hours."
    fi
done

generate_running_message_summary

echo -e "Found the following filtered errors in the logs:\n"
find "${root_d}" -name "${filtred_file_prefix}*" | sort
