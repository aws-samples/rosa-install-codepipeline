#!/bin/bash
set -x
set -e

BUILD_INPUT_FILE=~/.aws/rosa_input.env
BUILD_OUTPUT_FILE=~/.aws/rosa_output.env
BUILD_IO_ROOT_DIR=/home/rosa_install_user/rosa_install_io

ecr_login() {
    #pull rosa install container from ECR
    echo Logging in to Amazon ECR...
    aws ecr get-login-password --region "${ROSA_CLUSTER_REGION}" | docker login --username AWS --password-stdin "${AWS_ECR_ACCOUNT_ID}".dkr.ecr."${ROSA_CLUSTER_REGION}".amazonaws.com
    echo pulling "${AWS_ECR_ACCOUNT_ID}.dkr.ecr.${ROSA_CLUSTER_REGION}.amazonaws.com/${IMAGE_REPO_NAME}:${IMAGE_TAG_LATEST}"
    docker pull "${AWS_ECR_ACCOUNT_ID}".dkr.ecr."${ROSA_CLUSTER_REGION}".amazonaws.com/"${IMAGE_REPO_NAME}":"${IMAGE_TAG_LATEST}"
}
assume_role_in_another_account() {
    shellopts="$-"; if [[ "${shellopts}" =~ x ]]; then set +x; fi
    #assume role in account where ROSA needs to be installed and configured
    output="/tmp/assume-role-output.json"
    aws sts assume-role --role-arn "${ROLE_ARN_IN_ANOTHER_ACCOUNT}" --role-session-name "install-rosa-container-session" --output json --duration-seconds 3600 > "${output}"
    AccessKeyId=$(jq -r '.Credentials''.AccessKeyId' "${output}")
    SecretAccessKey=$(jq -r '.Credentials''.SecretAccessKey' "${output}")
    SessionToken=$(jq -r '.Credentials''.SessionToken' "${output}")

    export AWS_ACCESS_KEY_ID="${AccessKeyId}"
    export AWS_SECRET_ACCESS_KEY="${SecretAccessKey}"
    export AWS_SESSION_TOKEN="${SessionToken}"
    set -x
}

retrieve_rosa_params_env() {
    #retrieve rosa_params.env added to the rosa install code commit repo
    ls -al ; if [ ! -d  .git ] ; then echo 'please choose Output artifact format as Full clone for the codepipeline SourceStageCodeCommit stage' ; fi 
    if [[ -z "${CODEBUILD_RESOLVED_SOURCE_VERSION}" ]]; then echo "CODEBUILD_RESOLVED_SOURCE_VERSION not avaialble" ; return 1 ; fi
    git show "63662d42402aff24a6191d0cb006fe2733e89efa" --name-only | grep "^rosa_cluster" | grep "rosa_params.env" || true
    ROSA_PARAMS_ENV=$(git show "${CODEBUILD_RESOLVED_SOURCE_VERSION}"  --name-only | grep "^rosa_cluster" | grep "rosa_params.env" || true )
    if [[ -z "$ROSA_PARAMS_ENV" ]]; then echo "rosa_params.env not updated in git commit id ${CODEBUILD_RESOLVED_SOURCE_VERSION}" ; EXECUTE_ROSA_CONTAINER= ; return 1 ; fi
    BN="$(basename "${ROSA_PARAMS_ENV}")"
    ROSA_PARAMS_ENV_DIR=$(echo "$ROSA_PARAMS_ENV" | sed -e 's@'"$BN"'@@')
    echo "${ROSA_PARAMS_ENV_DIR}"
    cp "${ROSA_PARAMS_ENV}" "${ROSA_PARAMS_ENV}".bak
    ROLE_ARN_IN_ANOTHER_ACCOUNT="${ROSA_INSTALL_CONTAINER_ROLE_ARN}"
    assume_role_in_another_account
    env | grep AWS >> "${ROSA_PARAMS_ENV}"
    env | grep ROSA >> "${ROSA_PARAMS_ENV}"
    grep -v -e SECRET -e ACCESS -e TOKEN "${ROSA_PARAMS_ENV}" # for debugging, don't echo secrets
    EXECUTE_ROSA_CONTAINER=Y
    echo "ROSA_PARAMS_ENV=${ROSA_PARAMS_ENV}" >> "${BUILD_INPUT_FILE}"
    echo "EXECUTE_ROSA_CONTAINER=${EXECUTE_ROSA_CONTAINER}" >> "${BUILD_INPUT_FILE}"
    echo "EXECUTE_ROSA_CONTAINER=${EXECUTE_ROSA_CONTAINER}" >> "${BUILD_INPUT_FILE}"
    echo -n "" > "${BUILD_OUTPUT_FILE}"
    chmod a+w "${BUILD_OUTPUT_FILE}"
}

associate_vpcs() {
    if [[ -n "${ROSA_PRIVATE_HOSTED_ZONES}" ]] ; then 
        echo 'Associating VPC with ROSA PHZ'
        for i in ${ROSA_PRIVATE_HOSTED_ZONES//,/ }  ; do 
            if [[ -n "${AWS_SHARED_SERVICES_VPC_ID}" ]]; then
                aws route53 associate-vpc-with-hosted-zone --hosted-zone-id "$i" --vpc "VPCRegion=${ROSA_CLUSTER_REGION},VPCId=$AWS_SHARED_SERVICES_VPC_ID" --comment "associated ${ROSA_PRIVATE_HOSTED_ZONES} with ${AWS_SHARED_SERVICES_VPC_ID}" || true 
                if [[ -n "${AWS_CUSTOMER_CORP_VPC_ID}" ]]; then
                    aws route53 associate-vpc-with-hosted-zone --hosted-zone-id "$i" --vpc "VPCRegion=${ROSA_CLUSTER_REGION},VPCId=$AWS_CUSTOMER_CORP_VPC_ID" --comment "associated ${ROSA_PRIVATE_HOSTED_ZONES} with ${AWS_SHARED_SERVICES_VPC_ID}" || true 
                fi
            fi
        done  
        if [[  -n "${NETWORK_HUB_PHZ_VPC_ASSOC_ROLE_ARN}" && -n "${AWS_NETWORK_HUB_VPC_ID}" ]]; then
            ROLE_ARN_IN_ANOTHER_ACCOUNT="${NETWORK_HUB_PHZ_VPC_ASSOC_ROLE_ARN}"
            assume_role_in_another_account
            for i in ${ROSA_PRIVATE_HOSTED_ZONES//,/ } ; do 
                aws route53 associate-vpc-with-hosted-zone --hosted-zone-id "$i" --vpc "VPCRegion=${ROSA_CLUSTER_REGION},VPCId=$AWS_NETWORK_HUB_VPC_ID" --comment "associated ${ROSA_PRIVATE_HOSTED_ZONES} with ${AWS_SHARED_SERVICES_VPC_ID}" || true 
                if [[ -n "$AWS_NETWORK_HUB_INSPECTION_VPC_ID" ]]; then
                    aws route53 associate-vpc-with-hosted-zone --hosted-zone-id "$i" --vpc "VPCRegion=${ROSA_CLUSTER_REGION},VPCId=$AWS_NETWORK_HUB_INSPECTION_VPC_ID" --comment "associated ${ROSA_PRIVATE_HOSTED_ZONES} with ${AWS_SHARED_SERVICES_VPC_ID}" || true 
                fi
            done
        fi
    fi
}

share_private_certificate_authority() {
    if [[ -n "${AWS_ACM_PRIVATE_CA_ARN}" && -n "${AWS_ROSA_ACCOUNT_ID}" ]] ; then 
        aws ram create-resource-share --name Shared_Private_CA --resource-arn "${AWS_ACM_PRIVATE_CA_ARN}" --principals "${AWS_ROSA_ACCOUNT_ID}" || true
    fi   
}

pre_build() {
    aws configure set default.region "${ROSA_CLUSTER_REGION}"
    ecr_login
}

build() {
    if [[ -n "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" ]]; then
        # enable temporary access to the internet
        aws ec2 authorize-security-group-egress \
            --group-id "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" \
            --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]' || true
        aws ec2 authorize-security-group-egress \
            --group-id "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" \
            --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' || true
    fi 
    retrieve_rosa_params_env
    if [ -f "${BUILD_INPUT_FILE}" ]; then export $(cat ${BUILD_INPUT_FILE} | xargs) ;  fi
    if [[ -n "${EXECUTE_ROSA_CONTAINER}" && -n "${ROSA_PARAMS_ENV}" ]]; then docker run -v ~/.aws:"${BUILD_IO_ROOT_DIR}" --rm --env-file="${ROSA_PARAMS_ENV}" "${AWS_ECR_ACCOUNT_ID}".dkr.ecr."${ROSA_CLUSTER_REGION}".amazonaws.com/"${IMAGE_REPO_NAME}":"${IMAGE_TAG_LATEST}" "${ROSA_INSTALL_ACTION}" ; fi
}

post_build() {
    rm -rf ~/.aws/credentials
    aws sts get-caller-identity
    if [ -f "${BUILD_OUTPUT_FILE}" ]; then export $(cat ${BUILD_OUTPUT_FILE} | xargs) ; fi
    associate_vpcs
}

finally() {
    if [[ -n "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" ]]; then
        # revoke access to the internet
        aws ec2 revoke-security-group-egress \
            --group-id "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" \
            --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]' || true
        aws ec2 revoke-security-group-egress \
            --group-id "${AWS_CODEPIPELINE_SECURITY_GROUP_ID}" \
            --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' || true
    fi
}
if [[ -n "$1" ]]; then "$@" ; exit 0 ; fi