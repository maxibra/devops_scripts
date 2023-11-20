#!/usr/bin/env bash
# This tool performs a 'terraform apply' on all the provided directories and workspaces.

set -o pipefail   # the pipeline's return status is the value of the last (rightmost) command to exit with a non-zero status, or zero if all commands exit successfully.

run_cmd=$@
full_script_name=$0

##############################
# FUNCTIONS

function usage () {
  cat << EOF

!!! Please run this script in the root directory of the repository with the requested branch.

 USAGE:
    $0 -w WORKSPACES -a ACTION -s DIRS_SOURCE -w WORKSPACES [-x EXCLUDE_DIRS] [-h]

       -a ACTION       - Required. The action to perform: plan | apply
       -s DIRS_SOURCE  - Required. One from following options:
                            -- The list of directories to apply to, separated by whitespaces: 'aws/ecr aws/iam/account'
                            -- The full path to the file with one folder per row to apply or plan: /tmp/pr_folders.txt (output of collect_PR_folders.sh: 'List of all Folders')
                            -- The URI of the folder containing the plan output files within the S3 bucket: 's3://terraform-apply-logs/glasseson-terraform/2023/09/29/plan/PR_417_folders_2023-09-29-13-25/'
       -u              - Optional. Use it to create uncolor output
       -w WORKSPACES   - Required. Mutual excluded with '-s' in case of S3 URI. Workspaces to apply to, separated by '|': 'beta|sandbox|staging'
                                   !!! it's Required include workspaces of ALL configurations in the DIRS_SOURCE
       -x EXCLUDE_DIRS - Optional. List of folders to exclude, separated by '|': 'aws/ecs/go-replicator-cls|aws/s3/glasseson-assets'
       -h              - Optional. Show this usage
       Ctrl + C        - Stop the script

     For example:
        Workspaces (find . -name "*.tfvars" | rev | cut -d'/' -f 1 | rev | cut -d '.' -f1 | sort -u):
          - Dev:  'beta|madeye|mufasa|sandbox|shazam|staging'
          - Prod: 'dr|global|production|us-|eu-|xena'
        Running:
          Plan from a file of folders:              $0 -a plan -s /tmp/pr_folders.txt -w 'beta|madeye|mufasa'
          Apply on-demand from list of folders:     $0 -a apply -s 'aws/ecr aws/iam/account' -w 'dr|global'
          Apply on-demand from a file with folders: $0 -a apply -s 'aws/ecr aws/iam/account' -w 'beta|madeye|mufasa|sandbox|shazam|staging'
          Apply from plan files in S3:              $0 -a apply -s 's3://terraform-apply-logs/glasseson-terraform/2023/09/29/plan/PR_417_folders_2023-09-29-13-25/' -w 'beta|madeye'

EOF
}

function cntr_c () {
  echo -e "\n\n\tThe program is terminated.\n\n"
  cp_to_bucket
  echo -e "\n\nYou can find the log file in '${log_file}' and ${S3_OBJECT}\n"
  exit 1
}

function cp_to_bucket {
  echo -e "\n-------------------\n\nUploading the files to S3.."
  aws s3 cp ${tmp_work_dir} ${S3_OBJECT} --recursive > /dev/null
  if [ $? -gt 0 ]; then
    echo -e "\n Failed to copy '${tmp_work_dir}' to S3 bucket.\n"
  fi
}

function cp_from_bucket {
  aws s3 cp ${DIRS_SOURCE} ${PLAN_FILES_DIR}/ --recursive
  if [ $? -gt 0 ]; then
    echo -e "\nFailed to copy PLAN files from '${DIRS_SOURCE}"
    exit 2
  fi
}

function set_slack_data {
  secret_val=$(aws secretsmanager get-secret-value --secret-id "Slack/app/ENvs_updates/Creds" --query "SecretString" --output text)
  ACCESS_TOKEN=$(echo ${secret_val} |  jq ".\"ACCESS_TOKEN\"" | tr -d "\"")
  DEFAULT_CHANNEL=$(echo ${secret_val} |  jq ".\"DEFAULT_CHANNEL\"" | tr -d "\"")
  TF_HEADER=$(echo ${secret_val} | jq --arg hdr "$TF_HDR" ".[\$hdr]" | tr -d "\"")
  TERRAFORM_SLACK_TEMPLATE=$(echo ${secret_val} |  jq ".\"TERRAFORM_SLACK_TEMPLATE\"" \
                                | sed "s/#DEFAULT_CHANNEL#/$DEFAULT_CHANNEL/" \
                                | sed "s/#HEADER#/$TF_HEADER/" \
                                | sed "s/#WORKSPACE#/$(terraform workspace show)/" \
                                | sed "s/#VERSION#/$(git describe --abbrev=0 --tags) \[$(git rev-parse HEAD \
                                | cut -c 1-6)\]/" \
                                | sed "s%#PROJECT#%$(pwd | sed "s/.*\/\(.*\)\/aws\/\(.*\)/\1\/aws\/\2/")%" \
                                | sed "s/#BRANCH#/${current_branch}/" \
                                | sed "s/#USER#/$USER/" \
                                | sed "s@#LOG_URI#@$S3_OBJECT@" \
                                | jq ".|fromjson")
}

function send2slack {
  if [ -z "$(echo ${WS_DONT_SENT2SLACK} | grep $(terraform workspace show))" ]; then
    set_slack_data
    slack_response=$(curl -s -f -X POST -H "Content-type: application/json" -H "Authorization: Bearer ${ACCESS_TOKEN}" -d "${TERRAFORM_SLACK_TEMPLATE}" https://slack.com/api/chat.postMessage)
    if [[ "$(echo ${slack_response} | jq ".ok")" == "false" ]]; then
      echo -e "Failed to send message to Slack:\n${slack_response}"
    fi
  fi
}

function print_log_header {
  echo "Terraform version: $(terraform --version)" | tee -a ${log_file}
  echo "---------------------" | tee -a ${log_file}
  echo "Running command: ${run_cmd}" | tee -a ${log_file}
  echo | tee -a ${log_file}
  echo "The log contains '${ACTION}'" | tee -a ${log_file}
  echo -e "\tFolders from:" | tee -a ${log_file}
  echo -e "\t\tOriginal list: ${FOLDERS_FILE}" | tee -a ${log_file}
  echo -e "\t\tWorking list:  ${working_folder_list}" | tee -a ${log_file}
  echo -e "\tWorkspaces: ${WORKSPACES}" | tee -a ${log_file}
  echo -e "\tWorking Folders:"
  echo "$(cat ${working_folder_list})" | tee -a ${log_file}
  echo -e "\n All exist workspaces in the repo:\n$(find . -name "*.tfvars" | rev | cut -d'/' -f 1 | rev | cut -d '.' -f1 | sort -u)"
  echo -e "\n=============================================================\n" | tee -a ${log_file}
}

function collect_folders {
  tmp_f=/tmp/folders_${clean_name_w_date}.txt

  if [ -n "${FOLDERS_FILE}" ] && [ -n "${EXCLUDE_DIRS}" ]; then
    cat "${FOLDERS_FILE}" | grep -Ev ${EXCLUDE_DIRS} > ${tmp_f}
  elif [ -n "${FOLDERS_FILE}" ]; then
    cp "${FOLDERS_FILE}" ${tmp_f}
  fi

  if [ -n "${PLAN_FILES_DIR}" ]; then # S3 URI
    cat ${PLAN_FILES_DIR}/meta_data_* | cut -s -d'#' -f2 | uniq > "${working_folder_list}"
  elif [ -n "${WORKSPACES}" ]; then   # a string or a file with the folders is given
    while read -r f; do
      for ws in $(echo "${WORKSPACES}" | tr '|' ' '); do
        ls ${f}/vars/*${ws}*.env.tfvars > /dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "${f}" >> "${working_folder_list}"
          break
        fi
      done
    done < ${tmp_f}
  else
    echo -e "\nERROR [collect_folders]: Both 'PLAN_FILES_DIR' and 'WORKSPACES' are missing"
    exit 1
  fi
}

function collect_workspaces {
  if [ -n "${PLAN_FILES_DIR}" ]; then # S3 URI
    workspaces=$(grep ${d} ${PLAN_FILES_DIR}/meta_data_* | cut -d'#' -f3)
  elif [ -n "${WORKSPACES}" ]; then
    workspaces=$(terraform workspace list | grep -E ${WORKSPACES})
  else
    echo -e "\nERROR [main]: Both 'PLAN_FILES_DIR' and 'WORKSPACES' are missing"
    exit 1
  fi
}

function define_plan_out_file {
  if [ -n "${PLAN_FILES_DIR}" ]; then # S3 URI
    tfplan_file=$(grep ${d} ${PLAN_FILES_DIR}/meta_data_* | grep ${ws} | cut -d'#' -f1)
    plan_out_file="${PLAN_FILES_DIR}/${tfplan_file}"
  else
    tfplan_file="$(pwd | rev | cut -d/ -f1 | rev)-${ws}.tfplan"
    plan_out_file="${tmp_work_dir}/${tfplan_file}"
  fi
}

function worspace_select {
  echo -e "\n++++++++++++++++++++++++++++\n++ ${ws} (${d})\n++++++++++++++++++++++++++++\n" | tee -a ${log_file}
  terraform workspace select ${UNCOLOR} ${ws} | tee -a ${log_file}
  terraform init ${UNCOLOR} --upgrade | tee -a ${log_file}
}

function plan_action {
  terraform plan ${UNCOLOR} -var-file=vars/${ws}.env.tfvars -out=${plan_out_file} | grep -v "Refreshing state...\|Reading...\|Read complete after" > ${tmp_plan_file}
  cat ${tmp_plan_file} | tee -a ${log_file}
  if [ -n "$(grep -E 'No changes\.|Error\:' ${tmp_plan_file})" ]; then
    rm -f ${plan_out_file}
  else
    echo "${tfplan_file}#${d}#${ws}" >> ${metadata_file}
  fi
}

function apply_action {
  if [ -z "${PLAN_FILES_DIR}" ]; then # On-demand apply (NOT S3 URI)
    terraform plan ${UNCOLOR} -var-file=vars/${ws}.env.tfvars -out=${plan_out_file} | grep -v "Refreshing state...\|Reading...\|Read complete after" | tee ${tmp_plan_file}
    cat ${tmp_plan_file} >> ${log_file}
    if [ -z "$(grep -E 'No changes\.|Error\:' ${tmp_plan_file})" ]; then
      echo -n "Do you approve the above changes in ${d} (${ws}) [yes|no]: " | tee -a ${log_file}
      read -r is_approved
      echo -e "\n\nYour choice is ${is_approved}\n" | tee -a ${log_file}
    fi
  fi

  if [ -n "${PLAN_FILES_DIR}" ] || [ "${is_approved}" == "yes" ]; then
    echo -e "\n--------------\nRunning apply from ${plan_out_file}\n" | tee -a ${log_file}
    TF_HDR="TERRAFORM_APPLY_HEADER"
    echo terraform apply ${UNCOLOR} ${plan_out_file} 2>&1 | tee -a ${log_file}
    if [ $? -eq 0 ]; then send2slack; fi
  fi
}

UNCOLOR=""
##############################
# PREREQUISITES

while getopts "a:s:uw:x:h" opt; do
  case ${opt} in
    a )
      ACTION="${OPTARG}"
      ;;
    s )
      DIRS_SOURCE="${OPTARG}"
      ;;
    u )
      UNCOLOR="-no-color"
      ;;
    w )
      WORKSPACES="${OPTARG}"
      ;;
    x )
      EXCLUDE_DIRS="${OPTARG}"
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

c_datetime=$(date +%Y-%m-%d-%H-%M)
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ ${DIRS_SOURCE} = s3://* ]]; then
  if [[ -n ${WORKSPACES} ]]; then
     echo -e "\nThe S3 URI and WORKSPACES are mutual excluded arguments. Please don't use them together."
    exit 1
  fi

  if [[ ${DIRS_SOURCE} = */ && -n "$(aws s3 ls ${DIRS_SOURCE})" ]]; then
    PLAN_FILES_DIR="/tmp/From_PLAN_$(echo ${DIRS_SOURCE} | rev | cut -d'/' -f2 | rev)"
    cp_from_bucket
  else
    echo -e "\nThe URI is invalid. Please ensure it ends with '/'."
    exit 1
  fi
elif [ -f "${DIRS_SOURCE}" ]; then  # it's path to folders' file
  FOLDERS_FILE=${DIRS_SOURCE}
elif [ -d "$(echo ${DIRS_SOURCE} | cut -d' ' -f1)" ]; then
  FOLDERS_FILE="manual"
  echo "${DIRS_SOURCE}" | tr ' ' '\n' > ${FOLDERS_FILE}
else
  echo -e "\nDIRS_SOURCE is invalid."
  usage
  exit 1
fi

if [ -n "${FOLDERS_FILE}" ]; then
  clean_name_w_date="PLAN_BR-${current_branch}-SRC-$(echo ${FOLDERS_FILE} | rev | cut -d'/' -f1 | rev | cut -d'.' -f1)-T-${c_datetime}"
elif [ -n "${PLAN_FILES_DIR}" ]; then
  clean_name_w_date="APPLY_BR-${current_branch}-SRC-$(echo ${PLAN_FILES_DIR} | rev | cut -d'/' -f1 | rev)_APPLIED_AT_${c_datetime}"
else
  echo "Invalid source for clean_name_w_date"
  exit 1
fi

WS_DONT_SENT2SLACK="playground dr"
ROOT_DIRS="glasseson-terraform phi-terraform-health jarvis-terraform terraform-luna-apps"
REPO_NAME=$(pwd | rev | cut -d'/' -f1 | rev)
tmp_plan_file="/tmp/${clean_name_w_date}.tmp"
tmp_work_dir="/tmp/${clean_name_w_date}"
metadata_file="${tmp_work_dir}/meta_data_${clean_name_w_date}.txt"
log_file="${tmp_work_dir}/$(echo ${WORKSPACES} | tr '|' '_')_${clean_name_w_date}.log"
prj_path=$(pwd)
S3_OBJECT="s3://terraform-apply-logs/${REPO_NAME}/$(date +%Y)/$(date +%m)/$(date +%d)/${ACTION}/${clean_name_w_date}"
if [ -n "${PLAN_FILES_DIR}" ]; then
  working_folder_list="$(ls ${PLAN_FILES_DIR}/working_folders_*)"
else
  working_folder_list="${tmp_work_dir}/working_folders_${clean_name_w_date}.txt"
fi

if [ -z "${ACTION}" ] || [ -z "$(echo "plan apply" | grep ${ACTION})" ]; then
  echo -e "\n\tWrong ACTION is defined: '${ACTION}'"
  echo -e "\tPossible options: 'plan' or 'apply'\n"
  exit 1
fi

if [ -z "$(echo ${ROOT_DIRS} | grep ${REPO_NAME})" ]; then
  echo -e "\n\tIt appears that you are NOT in the root folder of the repository."
  echo -e "\tPlease rerun the script in the root directory of the repository with the requested branch.\n"
  exit 1
fi



##############################
# MAIN BLOCK

mkdir -p "${tmp_work_dir}" || exit 1
cp "${FOLDERS_FILE}" "${tmp_work_dir}/" 2> /dev/null

collect_folders
if [ ! -f "${working_folder_list}" ]; then
  echo -e "\nNothing to do. The working folder list is empty. Try another list of workspaces.\n"
  exit 2
fi

print_log_header
amount_dirs=$(cat "${working_folder_list}" | wc -l | tr -d ' ')
i=1
for d in $(cat "${working_folder_list}"); do
  echo -e "\n========================================\n==== ${d} [${i} / ${amount_dirs}]\n========================================\n" | tee -a ${log_file}
  cd "${d}" || exit
  terraform workspace select default > /dev/null
  echo -e "The folder contains following workspaces: $(terraform workspace list)\n"  | tee -a ${log_file}

  collect_workspaces
  for ws in $(echo ${workspaces}); do
    trap cntr_c SIGTERM SIGINT

    worspace_select
    define_plan_out_file
    if [ "${ACTION}" == "plan" ]; then
      plan_action
    else
      apply_action
    fi
  done
  cd "${prj_path}" || exit
  i=$((i+1))
done

cp_to_bucket

echo -e "\n\nYou can find the log file in the following locations:"
echo -e "\tLocal: '${log_file}'"
echo -e "\tS3:    '${S3_OBJECT}'\n"
