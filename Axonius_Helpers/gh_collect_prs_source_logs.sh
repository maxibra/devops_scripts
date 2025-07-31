#!/usr/bin/env bash

# Collect source branches of PRs opened and closed in the last 24 hours for a given GitHub repository
# This script uses the GitHub CLI (gh) to list pull requests and jq to filter and format the output.
# Usage: ./gh_collect_prs_source_logs.sh <repo> [limit]
# Example: ./gh_collect_prs_source_logs.sh Axonius/axonius-cloud 50



# Check dependencies
if ! command -v gh >/dev/null; then
    echo "Error: gh CLI is required. Install from https://cli.github.com/" >&2
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "Error: jq is required. Install with 'brew install jq' or from https://stedolan.github.io/jq/" >&2
    exit 1
fi

# Usage: script.sh <repo> [limit]
if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo> [limit]"
    exit 1
fi
repo="$1"
limit="${2:-100}"

# Collect source branches of PRs opened and closed in the last 24 hours for given repo
from_t=$(date -u -v-24H +%s)
output_dir="/tmp/prs_source_branches"
mkdir -p "${output_dir}"
out_file="${output_dir}/${repo//\//_}_prs_branches.txt"
raw_data="${output_dir}/${repo//\//_}_prs_branches_raw_data.txt"

# Opened PRs in last 24h
echo "${repo}: collecting last ${limit} PRs in last 24h..."
gh pr list --repo "${repo}" --state all --limit "${limit}" \
  --json number,headRefName,headRepositoryOwner,createdAt,state > "${raw_data}"

jq -r '.[] | "\(.number) - \(.createdAt) - \(.state) - \(.headRepositoryOwner.login):\(.headRefName)"' "${raw_data}" > "${out_file}"

echo "PR source branches collected under ${output_dir}"
