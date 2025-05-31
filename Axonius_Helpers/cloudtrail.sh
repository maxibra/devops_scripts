!#/bin/bash
# This script looks up AWS CloudTrail events for AssumeRoleWithWebIdentity
# for a specific session name within a specified time range.
# Usage: ./cloudtrail.sh


hours_back_start=5
hours_back_end=0
r="us-east-2"
p="139388023521:read-only"
session_name="cortex_60274-merge_15255121314"

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --region ${r} --profile ${p} --output json \
  --query 'Events[].CloudTrailEvent' \
  --start-time $(date -u -v-${hours_back_start}H +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u -v-${hours_back_end}H  +%Y-%m-%dT%H:%M:%SZ) > /tmp/cloudtrail_assume_role.json

cat /tmp/cloudtrail_assume_role.json \
  | jq ".[] | fromjson | select(.requestParameters.roleSessionName == \"${session_name}\")"