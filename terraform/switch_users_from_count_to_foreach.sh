#!/bin/bash

declare -i N=3
while read U; do
  terraform state mv "module.admin_iam_users[$N].aws_iam_user.user" "module.admin_iam_users[\"$U\"].aws_iam_user.user"
  terraform state mv "module.admin_iam_users[$N].aws_iam_user_group_membership.group_membership[0]" "module.admin_iam_users[\"$U\"].aws_iam_user_group_membership.group_membership[0]"
  terraform import "module.admin_iam_users[\"$U\"].aws_iam_user_login_profile.login_profile[0]" $U
  terraform state rm "module.admin_iam_users[$N].aws_iam_user_login_profile.login_profile[0]"
    (( N++ ))
done <<EOT
max@6over6.com
