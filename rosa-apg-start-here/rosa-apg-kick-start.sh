#!/bin/bash
set -e

# Check for prereqs.
if ! command -v jq &> /dev/null
then
    echo "jq could not be found, please install jq."
    exit
fi

if ! command -v aws &> /dev/null
then
    echo "AWS CLI could not be found, please install AWS CLI version 2 or higher."
    exit
fi

echo "create a S3 bucket to store the ROSA GitOps source code in a zip for the rosa-install stack to create AWS CodeCommit repos and populate them"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REGION=$(aws configure get region --output text)
ROSA_ZIPS_BUCKET="rosa-input-${ACCOUNT_ID-$REGION}"
aws s3 ls "${ROSA_ZIPS_BUCKET}" > /dev/null 2>&1 || aws s3 mb s3://"${ROSA_ZIPS_BUCKET}" 

cd ../rosa-install/
zip -r ../rosa-apg-start-here/rosa-install.zip ./* -x ".git/*"
cd ../rosa-uninstall/
zip -r ../rosa-apg-start-here/rosa-uninstall.zip ./* -x ".git/*"
cd ../rosa-codepipeline-buildspec-scripts/
zip -r ../rosa-apg-start-here/rosa-codepipeline-buildspec-scripts.zip ./* -x ".git/*"
cd ../rosa-infrastructure/
zip -r ../rosa-apg-start-here/rosa-infrastructure.zip ./* -x ".git/*"
cd ../rosa-apg-start-here

aws s3 cp rosa-install.zip s3://"${ROSA_ZIPS_BUCKET}"
aws s3 cp rosa-uninstall.zip s3://"${ROSA_ZIPS_BUCKET}"
aws s3 cp rosa-codepipeline-buildspec-scripts.zip s3://"${ROSA_ZIPS_BUCKET}"
aws s3 cp rosa-infrastructure.zip s3://"${ROSA_ZIPS_BUCKET}"

aws cloudformation package --template ../rosa-infrastructure/rosa-install.yaml --s3-bucket "${ROSA_ZIPS_BUCKET}" --output-template-file rosa-install-root-template.yaml


if aws cloudformation describe-stacks --stack-name "rosa-install-root" > /dev/null 2>&1 ; then
    echo "Update the rosa-install stack if it exists" ;
    aws cloudformation update-stack --stack-name "rosa-install-root" \
    --template-body file://rosa-install-root-template.yaml \
    --parameters ParameterKey=pEnvironmentName,ParameterValue=ROSA \
                 ParameterKey=pROSAInstallCodeBucket,ParameterValue="${ROSA_ZIPS_BUCKET}" \
                 ParameterKey=pCreateRosaTokenSecret,ParameterValue="false" \
    --capabilities CAPABILITY_IAM && 
    (
        aws cloudformation wait stack-update-complete --stack-name "rosa-install-root"
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "rosa-install-root" --query 'Stacks[0].StackStatus' --output text)
        if [[ $STACK_STATUS != "UPDATE_COMPLETE" ]]; then
            echo 'Failed to update ROSA install stack. please check CloudFormation Stacks in AWS Console'
            exit 1;
        fi
    )
else 
    echo "Create the rosa-install stack if it doesn't exists"
    aws cloudformation create-stack --stack-name "rosa-install-root" \
    --template-body file://rosa-install-root-template.yaml \
    --parameters ParameterKey=pEnvironmentName,ParameterValue=ROSA \
                 ParameterKey=pROSAInstallCodeBucket,ParameterValue="${ROSA_ZIPS_BUCKET}" \
                 ParameterKey=pCreateRosaTokenSecret,ParameterValue="false" \
    --capabilities CAPABILITY_IAM &&
    (
        aws cloudformation wait stack-create-complete --stack-name "rosa-install-root"
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "rosa-install-root" --query 'Stacks[0].StackStatus' --output text)
        if [[ $STACK_STATUS != "CREATE_COMPLETE" ]]; then
            echo 'Failed to create ROSA install stack. please check CloudFormation Stacks in AWS Console'
            exit 1;
        fi
    )
fi