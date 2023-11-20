#!/usr/bin/env bash

# This tool gathers all modified directories from the provided pull request or
# from the given branch that haven't been merged into the develop yet.

set -o pipefail   # the pipeline's return status is the value of the last (rightmost) command to exit with a non-zero status, or zero if all commands exit successfully.

##############################
# FUNCTIONS

function find_dependencies {
  echo -e "\nCreating a list of dependencies based on 'terraform_remote_state' in data.tf"
  all_dependencies=""
  all_dependencies_echo=""

  for d in $(cat ${original_file} | grep aws); do
    if [ -f ${d}/data.tf ]; then
      dependencies="";
      for dd in $(grep -A10 "terraform_remote_state" ${d}/data.tf | grep key | cut -d'/' -f3- | tr -d '"'); do
        df=$(grep "aws/${dd}" ${original_file})   # check if the parent folder exists in the PR's repository
        if [ -n "${df}" ]; then dependencies="${df},${dependencies}"; fi
      done
      if [ -n "${dependencies}" ];then
        all_dependencies="${all_dependencies}\n${d}:${dependencies}"
        all_dependencies_echo="${all_dependencies_echo}\n'${d}'\tdepends on:\t${dependencies}"
      fi
    fi
  done
  echo -e "${all_dependencies}" > ${dependencies_ordered_file}
}

function liner_mover {
    row_to_move=$1
    row_before=$2

    tmp_file=/tmp/liner_mover_tmp.txt
    tmp_wo_row_file=/tmp/without_row_to_move.txt
    line_number_to_move=$(grep -nE "^${row_to_move}$" ${file_w_dependencies} | cut -d':' -f1)
    line_number_before=$(grep -nE "^${row_before}$" ${file_w_dependencies} | cut -d':' -f1)
    echo "TO_MOVE: ${line_number_to_move}; BEFORE: ${line_number_before}"
    echo "ROW_TO_MOVE: '${row_to_move}'; ROW_BEFORE: '${row_before}'"
    if [ ${line_number_to_move} -gt ${line_number_before} ]; then
        sed "\%$row_to_move%d" ${file_w_dependencies} > ${tmp_wo_row_file}
        if [ ${line_number_before} -eq 1 ]; then
            {
                echo ${row_to_move};
                cat ${tmp_wo_row_file}
            } > ${tmp_file}
        else
            to_row_number=$((line_number_before-1));
            {
                head -n ${to_row_number} ${file_w_dependencies};
                echo ${row_to_move};
                tail -n +${line_number_before} ${tmp_wo_row_file}
            } > ${tmp_file}
        fi
        mv ${tmp_file} ${file_w_dependencies}
    fi
}

function recreate_with_dependencies {
  reference_file=/tmp/dependencies_reference.txt
  cp ${file_w_dependencies} ${reference_file}
  echo "STAM" >> ${reference_file}
  i=1
  echo -ne "Creating file with the dependencies. Iterations: "
  while [ -n "$(diff ${file_w_dependencies} ${reference_file})" ] && [ $i -lt 10 ]; do
      echo -n "${i} "
      while read -r line; do
          dependent=$(echo ${line} | cut -d':' -f1 | tr -d ',')
          for dependency in $(echo ${line} | cut -d':' -f2 | tr ',' ' '); do
              if [ -z "${dependency}" ] || [ "${dependency}" == "${dependent}" ]; then continue; fi
              liner_mover ${dependency} ${dependent}
              if [ -z "$(grep ${dependency} ${dependecies_only_file})" ]; then
                echo ${dependency} >> ${dependecies_only_file}
              fi
          done
      done < ${dependencies_ordered_file}

      cp ${file_w_dependencies} ${reference_file}
      i=$((i+1))
  done
  echo
  rm -f ${reference_file}
}

function usage () {
  cat << EOF

!!! Please execute this script in the root directory of the repository with the requested branch.

 USAGE:
    $0 [-b BRANCH_NAME] [-g PR_NUMBER] -r REPO_NAME [-h]

       -b BRANCH_NAME - Flag to collect from diff between the current branch and develop.
                          !!! It is recommended to use the '-g' option to prevent local changes from interfering with the result. !!!
       -g PR_NUMBER   - Option to retrieve from Github using the provided PR number.
       -r REPO_NAME   - Required. The name of the repository to operate on.
       -h             - Optional. Show this usage

     For example:
        Branch:  $0 -b MY_BRANCH -r glasseson-terraform
        GitHub:  $0 -g 420 -r glasseson-terraform
EOF
}


##############################
# PREREQUISITES

while getopts "b:g:r:h" opt; do
  case ${opt} in
    b )
      BRANCH_NAME="${OPTARG}"
      PREFIX="branch_${BRANCH_NAME}"
      ;;
    g )
      PR_NUMBER="${OPTARG}"
      PREFIX="PR_${PR_NUMBER}"
      ;;
    r )
      REPO_NAME="${OPTARG}"
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

if [ -z "${REPO_NAME}" ]; then
  echo -e "\nThe repository name is necessary: -r REPO_NAME.\n"
  exit 1
elif [ "$(pwd | rev | cut -d'/' -f1 | rev)" != "${REPO_NAME}" ]; then
  echo -e "\nPlease execute the script from the root directory of the repository '${REPO_NAME}'\n"
  exit 1
fi

tmp_file=/tmp/${PREFIX}_tmp.txt
original_file=/tmp/${PREFIX}_folders_original.txt
file_w_dependencies=/tmp/${PREFIX}_original_folders.txt
dependencies_ordered_file=/tmp/${PREFIX}_dependencies_list.txt      # List of dependents with their "parents" (dependent:parent1,parent2,)
dependecies_only_file=/tmp/${PREFIX}_dependencies_only_list.txt  # list only of dependencies ("parents")
> ${dependecies_only_file}

##############################
# MAIN BLOCK

if [ -n "${PR_NUMBER}" ]; then
  if [[ -z "${GH_TOKEN}" ]]; then
    echo -e "\nGH_TOKEN is undefined\n"
    exit 1
  fi
  echo -e "\nCollecting from Github"

  page=1
  res=$(echo world$w{1..100})
  rm -f ${tmp_file}
  while [ $(echo ${res} | wc -w | awk '{print $1}') -ge 100 ]; do
    res=$(curl -L -s \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/6over6/${REPO_NAME}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}" \
        | jq '.[]' | jq '.filename')
    echo "${res}" >> ${tmp_file}
    page=$((page+1))
  done
  cat ${tmp_file} > ${original_file}
elif [ -n "${BRANCH_NAME}" ]; then
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "${BRANCH_NAME}" ]; then
      echo "'$(git rev-parse --abbrev-ref HEAD)' : '${BRANCH_NAME}'"
      echo -e "\n!!!! Please execute the script on the requested branch.!!\n"
      exit 1
    fi
    echo -e "\nCollecting by git diff"

    git --no-pager diff --diff-filter=MA --name-status develop | awk '{print $2}' > ${original_file}
else
  echo -e "\nPlease use -b or -g options\n"
  usage
  exit 1
fi

cat ${original_file} | grep -vE 'README\.md|\.terraform|versions\.tf' | sed 's#\(.*\)/vars#\1#' | cut -d'"' -f2 | rev | cut -d'/' -f2- | rev | sort -u > ${tmp_file}
mv ${tmp_file} ${original_file}

find_dependencies
cp ${original_file} ${file_w_dependencies}
recreate_with_dependencies
if [ -n "${all_dependencies_echo}" ]; then
  echo -e "${all_dependencies_echo}"
fi

echo -e "\nThe folders list exist in"
echo -e "\tList of all Folders: ${file_w_dependencies}"
echo -e "\tList of dependencies: ${dependecies_only_file}"
echo -e "\n\t!!! If your PR changes really do not affect any dependents, please remove the corresponding rows from the last file. !!!!"
echo -e "\t!!! This action will help prevent unnecessary complexity in the apply process. 's3/glasseson-models'?                !!!!"


