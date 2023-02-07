#!/bin/bash
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

REGION=$(aws configure get region --output text)

echo "delete zip files in current directory"
rm -f ./*.zip

echo "check if ROSA clusters have been deleted"
ROSA_INSTANCES=$(aws ec2 describe-instances --region "${REGION}" --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}"  --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='rosa*master*'"  --output text) 
if [ -n "$ROSA_INSTANCES" ]; then echo "please run the ROSA-Delete-Pipeline to delete existing ROSA clusters" ; exit 1; fi

echo "cleanup shared registry"
aws ecr batch-delete-image --repository-name amazon/aws-cli --image-ids imageTag=mylatest --region "${REGION}" >& /dev/null 2>&1
aws ecr batch-delete-image --repository-name rosa-install --image-ids imageTag=latest --region "${REGION}" >& /dev/null 2>&1
IMAGES_TO_DELETE=$( aws ecr list-images --region "${REGION}" --repository-name rosa-install --filter "tagStatus=UNTAGGED" --query 'imageIds[*]' --output json > /dev/null 2>&1 )
if [ "$IMAGES_TO_DELETE" != '' ] && [ "$IMAGES_TO_DELETE" != '[]' ] ; then aws ecr batch-delete-image --region "${REGION}" --repository-name rosa-install --image-ids "$IMAGES_TO_DELETE" >& /dev/null || true ; fi

echo "cleanup code commit repository which may have some commits to them"
aws codecommit delete-repository --repository-name rosa-install
aws codecommit delete-repository --repository-name 	rosa-uninstall

echo "cleanup IAM ManagedOpenShift Roles and Policies ManagedOpenShift-ControlPlane-Role ManagedOpenShift-Installer-Role ManagedOpenShift-Support-Role ManagedOpenShift-Worker-Role"
aws iam list-roles --output json | jq -r '.Roles[] | select(.RoleName | startswith("ManagedOpenShift-")) | .RoleName' | \
  while read -r role_name ; do \
    aws iam list-instance-profiles-for-role --role-name "${role_name}" --output json | \
    jq -r '.InstanceProfiles[] | .InstanceProfileName' | \
    while read -r instance_profile_name; do \
      aws iam remove-role-from-instance-profile --instance-profile-name "${instance_profile_name}" --role-name "${role_name}" || true ; \
      aws iam delete-instance-profile --instance-profile-name "${instance_profile_name}" || true ; \
    done ; \
    aws iam list-attached-role-policies --role-name "${role_name}" --output json | \
    jq -r '.AttachedPolicies[] | .PolicyArn' | \
    while read -r policy_arn; do \
      aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" || true ; \
      aws iam list-policy-versions --query "Versions[?@.IsDefaultVersion == \`false\`].VersionId" --policy-arn "${policy_arn}" --output text | \
      xargs -n 1 -I{} aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id {} || true ; \
      aws iam delete-policy --policy-arn "${policy_arn}" || true ; \
    done ;  \
    aws iam delete-role --role-name "${role_name}" || true ; \
  done 

aws iam list-policies --output json | jq -r '.Policies[] | select(.PolicyName | startswith("ManagedOpenShift-")) | .Arn' | \
    while read -r policy_arn; do \
      aws iam list-policy-versions --query "Versions[?@.IsDefaultVersion == \`false\`].VersionId" --policy-arn "${policy_arn}" --output text | \
      xargs -n 1 -I{} aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id {} || true ; \
      aws iam delete-policy --policy-arn "${policy_arn}" || true ; \
    done 


echo "cleanup S3 buckets"
aws s3 ls | awk '{print $3}' | grep pipelineartifacts | \
  while read -r bucket ; do 
    aws s3api delete-objects \
    --bucket "${bucket}" \
    --delete "$(aws s3api list-object-versions \
                --bucket "${bucket}" \
                --output=json \
                --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" > /dev/null 2>&1 ;
    aws s3api delete-objects \
    --bucket "${bucket}" \
    --delete "$(aws s3api list-object-versions \
                --bucket "${bucket}" \
                --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" > /dev/null 2>&1 ;
    aws s3 rm s3://"${bucket}" --recursive ; 
    aws s3 rb s3://"${bucket}" --force ; 
  done
aws s3 ls | awk '{print $3}' | grep rosa-input | while read -r bucket ; do aws s3 rm s3://"${bucket}" --recursive; aws s3 rb s3://"${bucket}" --force ; done
echo "remove rosa-install stack and wait"
aws cloudformation delete-stack --stack-name "rosa-install-root"
aws cloudformation wait stack-delete-complete --stack-name "rosa-install-root"

