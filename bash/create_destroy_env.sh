#!/bin/bash

function usage () {
  cat << EOF

!!! Before running this script, please ensure that all S3 buckets are EMPTY by using the script 'empty_s3_buckets.sh'.

 USAGE:
    $0 -c COMPONENTS_FILE -r REPO_PATH -t TERRAFORM_ACTION [-a] [-i] [-w DEFAULT_WORKSPACE]

       -a                   - Optional. Run the terraform command with '-auto_approve'
       -b                   - Optional. The default git branch. If this parameter is not defined, the default branch used will be the 'develop' branch.
       -c COMPONENTS_FILE   - Required. The path to the file containing the components. Please see the format of the file below.
       -i                   - Optional. Run 'terraform init -reconfigure -upgrade' in every folder
       -r REPO_PATH         - Required. The relative or full path to the folder containing all the components (including the 'aws' folder if it exists)
       -t TERRAFORM_ACTION  - Required. plan | apply | destroy
       -w DEFAULT_WORKSPACE - Optional. The option to define a default workspace
       -h                   - Show this usage
       Ctrl + C             - Stop the script

     For example: $0 -r ../../../jarvis-terraform/aws -t plan -c envs_resources/jarvis -i -w playground

  envs_resources/example format:
       1. Components listed per row in the order of their dependency for creation.
       2. Rows starting with '#' will be skipped.
       3. Row format: COMPONENT[:WORKSPACE[,WORKSPACES]][=BRANCH][@IMPORT_ADDR|ID[,IMPORT_ADDR|ID]]
           The described order is important and critical!
           3.1 COMPONENT  - path to the folder of the component without REPO_PATH.
           3.2 WORKSPACES - Optional list of workspaces separated by comma.
           3.3 BRANCH     - Optional git Branch. Without it the script uses the 'develop' branch.
           3.4 IMPORT_ADDR|ID - separate several imports by comma.
                - IMPORT_ADDR - The ADDR specified is the address to which the resource should be imported.
                                !! If the ADDR contains double quotes escape them in the file, for example my_id[\"sub_id\"]
                - ID          - The ID is a resource-specific ID to identify that resource being imported.

       To see an example run 'cat envs_resources/example'

EOF
}

while getopts "ab:c:ir:t:w:h" opt; do
  case ${opt} in
    a )
      AUTO_APPROVE="-auto-approve"
      ;;
    c )
      COMPONENTS=$(grep -v '^#' ${OPTARG})
      ;;
    b )
      DEFAULT_BRANCH="${OPTARG}"
      ;;
    i ) # TERRAFORM_INIT
      TERRAFORM_INIT="true"
      ;;
    r )
      REPO_PATH="${OPTARG}"
      ;;
    t )
      TERRAFORM_ACTION="${OPTARG}"
      ;;
    w ) # DEFAULT_WORKSPACE
      DEFAULT_WORKSPACE="${OPTARG}"
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
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
DONT_DESTROY_WORKSPACES="global production eu europe us"  # The workspace name that contains any word from the "list" will not be destroyed.
EXCLUDE_WORKSPACES="grp"  # Multi values format: "grp|something", using by `grep -Ev "$EXCLUDE_WORKSPACES"

function cntr_c () {
  echo -e "\n\n\tThe program is terminated.\n\n"
  exit 1
}

# Validate required arguments
if [ -z "${REPO_PATH}" ] || [ -z "${TERRAFORM_ACTION}" ] || [ -z "${COMPONENTS}" ]; then
  echo "Missing required argument(s)." 1>&2
  usage
  exit 1
fi

if [ -z "${DEFAULT_BRANCH}" ]; then
  DEFAULT_BRANCH="develop"
fi

cd "${REPO_PATH}" || exit
PROJECT_PATH=$(pwd)

for component in $(echo "${COMPONENTS}"); do
  cmp=$(echo ${component} | cut -d':' -f1)
  workspaces=$(echo ${component} | cut -s -d':' -f2 | tr ',' ' ')
  if [ -z "${workspaces}" ]; then workspaces=${DEFAULT_WORKSPACE}; fi
  if [ -z "${workspaces}" ]; then
    echo -e "\n${RED}[ERROR] The env_resources file doesn't define workspaces for '${cmp}' and default workspace is missing${NC}\n"
    exit 2
  fi
done

if [ "${TERRAFORM_ACTION}" == "destroy" ]; then
  echo -en "\n${RED}You are about to DESTROY THE ENTIRE environment of '${PROJECT_PATH}'${NC}"
  if [ -n "${DEFAULT_WORKSPACE}" ]; then
    echo " in ${DEFAULT_WORKSPACE}."
  fi
  echo -e "\n!!!! Please think carefully !!!!!\n"
  echo -n "Are you sure? yes/n: "
  read -r answer
  if [ "${answer}" != "yes" ]; then exit; fi

  if [ -n "${AUTO_APPROVE}" ]; then
    echo -e "\n${RED}!!!!! You have chosen to destroy WITHOUT approval  !!!!!\n"
    echo -n "Are you sure? yes/n: ${NC}"
    read -r answer
  fi
  if [ "${answer}" != "yes" ]; then exit; fi

  COMPONENTS=$(echo ${COMPONENTS} | rev)
fi

for component in ${COMPONENTS}; do
  trap cntr_c SIGTERM SIGINT

  if [ "${TERRAFORM_ACTION}" == "destroy" ]; then component=$(echo ${component} | rev); fi
  # awk '{$1=$1}1' removes extra spaces
  component_action=${TERRAFORM_ACTION}
  cmp=$(echo ${component} | cut -d':' -f1 | cut -d'=' -f1 | cut -d'@' -f1) # | awk '{$1=$11')
  workspaces=$(echo ${component} | cut -s -d':' -f2 | cut -d'=' -f1 | cut -d'@' -f1 | tr ',' ' ') # | awk '{$1=$1}1' | tr ',' ' ')
  branch=$(echo ${component} | cut -s -d'=' -f2 | cut -d'@' -f1) # | awk '{$1=$1}1')
  import_rsrc=$(echo ${component} | cut -s -d'@' -f2 | tr ',' ' ') # | awk '{$1=$1};1')

  if [ -z "${workspaces}" ]; then
    workspaces=${DEFAULT_WORKSPACE}
  fi

  if [ -z "${branch}" ]; then
    branch="${DEFAULT_BRANCH}"
  fi

  for workspace in ${workspaces}; do
    vars_file="vars/${workspace}.env.tfvars"
    echo -e "\n+++ ${component_action} (${AUTO_APPROVE}): ${branch} => ${cmp} => ${workspace} => ${vars_file}\n"
    cd "${PROJECT_PATH}/${cmp}" || exit
    pwd
    echo -e "------------------------------------------------------"
    git checkout "${branch}"
    if [ -n "${TERRAFORM_INIT}" ]; then
      terraform init -reconfigure
    fi

    echo -e "\n"
    if [ -z "$(terraform workspace list | grep ${workspace})" ]; then
      terraform workspace new ${workspace}
    else
      terraform workspace select ${workspace}
    fi
    echo -e "\n"

    # perform Import | state rm
    if [ -n "${import_rsrc}" ]; then
      for imprts in ${import_rsrc}; do
        import_addr=$(echo ${imprts} | cut -s -d'|' -f1)
        import_id=$(echo ${imprts} | cut -s -d'|' -f2)
        if [ "${component_action}" == "destroy" ] && [ -n "$(terraform state list | grep -F ${import_addr})" ]; then
          echo -e "\n\t${BLUE}+++ Removing state '${import_addr}'${NC}"
          terraform state rm "${import_addr}"
          if [ $? -ne 0 ]; then
            echo -e "\n${RED}[ERROR] FAILED to remove the state of ${import_addr}\n${NC}"
            exit 2
          fi
        elif [ "${component_action}" != "destroy" ] && [ -z "$(terraform state list | grep -F ${import_addr})" ]; then
          echo -e "\n\t${BLUE}+++ Importing state '${import_addr}'${NC}"
          terraform import -var-file=${vars_file} "${import_addr}" ${import_id}
          if [ $? -ne 0 ]; then
            echo -e "\n${RED}[ERROR] FAILED to import the state of ${import_addr}\n${NC}"
            exit 3
          fi
        fi
      done
    fi

    # Do not destroy the component if it is listed in the common usage list. Instead, modify it by applying changes.
    is_common_workspace=$(for wsc in ${DONT_DESTROY_WORKSPACES} ; do echo ${workspace} | grep -Ev "$EXCLUDE_WORKSPACES" | grep ${wsc}; done)
    if [ "${component_action}" == "destroy" ] && [ -n "${is_common_workspace}" ]; then
      echo "'${component}' in '${workspace}' => 'destroy' is changed to 'apply'."
      component_action="apply"
    fi

    terraform ${component_action} -var-file=${vars_file} ${AUTO_APPROVE}
    echo -e "\n============================================="
  done
done
