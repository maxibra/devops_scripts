#!/usr/bin/env bash

profile="health-dev"

echo -e "\n== Collecting account info..."
account_id=$(aws sts get-caller-identity --query "Account" --profile ${profile} --output text)
region=$(aws configure get region --profile ${profile} --output text)

base_docker="alpine" # alpine | aws
docker_file="Dockerfile-${base_docker}"
ecr_url="${account_id}.dkr.ecr.${region}.amazonaws.com"
image_version="${base_docker}-v0.1"
lambda_name="Storm-deploy"
lambda_role_name="${lambda_name}-Lambda"
layer_name="${lambda_name}-layer"
repo_name="storm/lambda-deploy"
repo_microservices_name="storm/basemicroservice-general"
tmp_file=/tmp/lambda_tmp.json
circleci_user="circleci-user"
circleci_policy="Inline-push-storm-basemicroservices"

image_full="${ecr_url}/${repo_name}:${image_version}"

echo -e "\n== Creating an Image ${image_full}..."
docker build -f ${docker_file} -t ${image_full} .

aws ecr get-login-password \
  --profile ${profile} | docker login \
  --username AWS \
  --password-stdin ${ecr_url}

echo -e "\n== Creating the Repo and Permissions ${repo_name}..."
aws ecr create-repository \
  --repository-name ${repo_name} \
  --tags "Key=Owner,Value=${USER} - manually" \
  --profile ${profile} 2>&1 | grep -v "already exists"

aws ecr set-repository-policy \
  --repository-name ${repo_name} \
  --policy-text file://iam/repo_policy.json \
  --profile ${profile}

echo -e "\n== Uploafing the Image ${image_full} to ECR..."
docker push ${image_full}

echo -e "\n== Creating User ${lambda_role_name}..."
aws iam create-user \
  --user-name ${circleci_user} \
  --tags "Key=Owner,Value=${USER} - manually" \
  --profile ${profile} 2>&1 | grep -v "already exists"

echo -e "\n== Adding inline policy to the User ${lambda_role_name}..."
cat iam/circleci_policy.json | \
  sed "s/#REGION#/$region/" | \
  sed "s/#ACCOUNT_ID#/$account_id/" | \
  sed "s@#BM_IMAGE#@$repo_microservices_name@" > ${tmp_file}

aws iam put-user-policy \
  --user-name ${circleci_user} \
  --policy-name ${circleci_policy} \
  --policy-document file://${tmp_file} \
  --profile ${profile}

echo -e "\n== Creating Lambda Role ${lambda_role_name}..."
aws iam create-role \
  --role-name ${lambda_role_name} \
  --assume-role-policy-document file://iam/lambda-trust-policy.json \
  --tags "Key=Owner,Value=${USER} - manually" \
  --profile ${profile} 2>&1 | grep -v "already exists"

cat iam/lambda-role-permission.json | \
  sed "s/#REGION#/$region/" | \
  sed "s/#ACCOUNT_ID#/$account_id/" | \
  sed "s@#REPOSITORY_NAME#@$repo_name@" | \
  sed "s/#FUNCTION_NAME#/$lambda_name/" | \
  sed "s/#LAYER_NAME#/$layer_name/" > ${tmp_file}

echo -e "\n== Attaching inline and execution policies to Lambda Role ${lambda_role_name} from ${tmp_file}..."
aws iam put-role-policy \
  --role-name ${lambda_role_name} \
  --policy-name inline-${lambda_name} \
  --policy-document file://${tmp_file} \
  --profile ${profile}

aws iam attach-role-policy \
  --role-name ${lambda_role_name} \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  --profile ${profile}

echo -e "\n== Creating the Lambda ${lambda_name}..."
aws lambda create-function \
  --function-name  ${lambda_name}\
  --package-type Image \
  --code ImageUri=${image_full} \
  --role "arn:aws:iam::${account_id}:role/${lambda_role_name}" \
  --tags "Key=Owner,Value=${USER} - manually" \
  --profile ${profile} 2>&1 | grep -v "already exist"

echo -e "\n== Updating the Image in Lambda ${lambda_name}..."
aws lambda update-function-code \
  --function-name ${lambda_name} \
  --image-uri ${image_full} \
  --profile ${profile}

echo -e "\n== Creating the EventBridge Rule ${lambda_name}..."
cat EventBridge/event_pattern.json | \
  sed "s@#REPOSITORY_NAME#@$repo_microservices_name@" | \
  sed 's/"/\\"/g' > ${tmp_file}

#  --event-pattern "$(cat ${tmp_file})" \
aws events put-rule \
  --name "${lambda_name}" \
  --event-pattern "{\"source\":[\"aws.ecr\"],\"detail-type\":[\"ECR Image Action\"],\"detail\":{\"action-type\": [\"PUSH\"],\"result\":[\"SUCCESS\"],\"repository-name\": [\"storm/basemicroservice-general\"]}}" \
  --event-bus-name default \
  --description "Invoke Lambda to create a new fast Environment after a new image is pushed to ECR" \
  --tags "Key=Owner,Value=${USER} - manually" \
  --profile ${profile}

echo -e "\n== Adding target to the EventBridge Rule ${lambda_name}..."
aws events put-targets \
  --rule ${lambda_name} \
  --targets "Id"="1","Arn"="arn:aws:lambda:${region}:${account_id}:function:${lambda_name}" \
  --profile ${profile}

echo -e "\n== Adding policy to the Lambda allow invoke from the EventBridge ${lambda_name}..."
aws lambda add-permission \
  --statement-id "InvokeLambdaFunction" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --function-name "arn:aws:lambda:${region}:${account_id}:function:${lambda_name}" \
  --source-arn "arn:aws:events:${region}:${account_id}:rule/${lambda_name}" \
  --profile ${profile} 2>&1 | grep -v "already exist"


# Destroying

#echo -e "\n== Removing target from the EventBridge rule ${lambda_name}..."
#aws events remove-targets \
#  --rule "${lambda_name}" \
#  --ids "1" \
#  --profile ${profile}
#
#echo -e "\n== Deleting the EventBridge rule ${lambda_name}..."
#aws events delete-rule \
#  --name ${lambda_name} \
#  --profile ${profile}

#echo -e "\n== Deleting the Lambda ${lambda_name}..."
#aws lambda delete-function \
#  --function-name ${lambda_name} \
#  --profile ${profile}
#
#echo -e "\n== Deleting the Repo ${repo_name}..."
#aws ecr delete-repository \
#  --repository-name ${repo_name} \
#  --force \
#  --profile ${profile}
#
#echo -e "\n== Deleting the Lambda Role ${lambda_role_name}..."
#aws iam delete-role \
#  --role-name ${lambda_role_name} \
#  --profile ${profile}

#echo -e "\n== Deleting Inline policy ${circleci_policy} from the User ${circleci_user}..."
#aws iam delete-user-policy \
#  --user-name ${circleci_user} \
#  --policy-name ${circleci_policy}\
#  --profile ${profile}

#echo -e "\n== Deleting the User ${circleci_user}..."
#aws iam delete-user \
#  --user-name ${circleci_user}\
#  --profile ${profile}
