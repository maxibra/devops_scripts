#!/bin/bash


function usage () {
  cat << EOF

USAGE:
   $0 -b BUCKETS [-p PROFILE] [-r REGION]
            -b BUCKETS - Required. The names of the buckets to be deleted, separated by commas.
            -p PROFILE - Optional. The name of the profile
            -r REGION  - Optional. The name of the region
            -h         - Show this usage
            Ctrl + C   - Stop the script

     For example: $0 -b my_bucket-1,my_bucket-1 -p health

EOF
}

while getopts "b:p:r:h" opt; do
  case ${opt} in
    b )
      BUCKETS=$(echo ${OPTARG} | tr ',' ' ')
      ;;
    p )
      PROFILE="--profile ${OPTARG}"
      ;;
    r )
      REGION="--region ${OPTARG}"
      ;;
    h ) # Help
      usage
      exit 0
      ;;
    \? ) # Invalid option
      echo "Invalid option: -$OPTARG" 1>&2
      usage
      exit 1
      ;;
    : ) # Missing argument
      echo "Option -$OPTARG requires an argument." 1>&2
      usage
      exit 1
      ;;
  esac
done

shift $((OPTIND -1))

function cntr_c () {
  echo -e "\n\n\tThe program is terminated.\n\n"
  exit 1
}

for bucket in ${BUCKETS}; do
  aws s3 rm "s3://${bucket}" --recursive ${PROFILE} ${REGION}
  versioning=$(aws s3api get-bucket-versioning --bucket "${bucket}" --query "Status" --output text ${PROFILE} ${REGION})
  if [ "${versioning}" == "Enabled" ]; then
    object_versions=$(aws s3api list-object-versions --bucket "${bucket}" --output=json \
                          --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' ${PROFILE} ${REGION})
    aws s3api delete-objects --bucket my-bucket \
      --delete "${object_versions}" ${PROFILE} ${REGION}
  fi
done
