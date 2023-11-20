#!/usr/bin/env bash

source_repo=$1  # git@github.com:6over6/glasseson-ops.git
target_repo=$2  # git@github.com:6over6/devops-tools.git
branch=$3
dir_to_move=$4  # scripts/terraform-bash/

source_dir=$(echo ${source_repo} | rev | cut -d'/' -f1 | rev | cut -d'.' -f1)

cd /tmp/ || exit
mkdir repo-migration
cd "repo-migration" || exit
git clone --branch ${branch} --origin origin --progress -v ${source_repo}
cd "${source_dir}"  || exit
git remote rm origin
#Thus you can, e.g., turn a library subdirectory into a repository of its own.
# Note the -- that separates filter-branch options from revision options, and the --all to rewrite all branches and tags.
git filter-branch --subdirectory-filter ${dir_to_move} -- --all   # -- all
git reset --hard
git gc --aggressive
git prune
git clean -fd
#git log
#ll
mkdir -p ${dir_to_move}
mv * ${dir_to_move}
#git status
git add .
git commit -m "${branch}: move back all files to directory ${dir_to_move }after filtering"
cd ../
git clone ${target_repo}
cd "$(echo ${target_repo} | rev | cut -d'/' -f1 | rev | cut -d'.' -f1)" || exit
git checkout -b ${branch}
git remote add old-repo ../${source_dir}
git config pull.rebase false
git pull old-repo ${branch} --allow-unrelated-histories
git remote remove old-repo
#git log
#git status
git push origin ${branch}
cd ../../
rm -rf repo-migration
