#!/bin/bash
set -x
set -e
ROSA_INSTALL_IO_ROOT_DIR="/home/rosa_install_user/rosa_install_io"
ROSA_PARAM_FILE="${ROSA_INSTALL_IO_ROOT_DIR}/rosa_params.env"
ROSA_OUTPUT_FILE="${ROSA_INSTALL_IO_ROOT_DIR}/rosa_output.env"

#uncomment the following line when ready to add extensions to rosa_install.sh in files named rosa_ext_<extension_name>.sh
#FILES="rosa_ext_*.sh" ; for ext in ${FILES} ; do [ -f "${ext}" ] && source "${ext}"  ; done

# read rosa_params.env file if it exists, alternatively expect that parameters are passed in through the environment
if [ -f "${ROSA_PARAM_FILE}" ]; then export "$(grep -v '^#' "${ROSA_PARAM_FILE}" | xargs -d '\n')"; fi

rosa_login() {
  shellopts="$-"; if [[ "${shellopts}" =~ x ]]; then set +x; fi
  aws configure set default.region "${ROSA_CLUSTER_REGION}"
  ROSA_TOKEN=$(aws secretsmanager get-secret-value  --secret-id ROSA_TOKEN --output json | jq -r '.SecretString')
  if [[ -z "${ROSA_TOKEN}" ]]; then echo 'Please provide ROSA token in a AWS Secrets Manager secret with name: ROSA_TOKEN' ; set -x ; return 1 ; fi
  rosa login --token="${ROSA_TOKEN}" --region "${ROSA_CLUSTER_REGION}"
  whoami
  set -x
}

whoami() {
  aws sts get-caller-identity --region "${ROSA_CLUSTER_REGION}" 
  rosa whoami --region "${ROSA_CLUSTER_REGION}" 
}

pre_create_secrets() {
  AWS_SECRET_NAME="ROSA_TOKEN"

  AWS_SECRET_NAME_EXISTS=$(aws secretsmanager list-secrets --output json | \
          jq -r --arg SECRET_NAME "${AWS_SECRET_NAME}" '.SecretList[] | select(.Name == $SECRET_NAME ) | .Name')

  if [[ -z "${AWS_SECRET_NAME_EXISTS}" ]]; then 
    if [[ -z "${ROSA_TOKEN}" ]]; then echo 'Please provide ROSA token in environment variable: ROSA_TOKEN' ; return 1 ; fi
    echo "Creating AWS Secrets Manager secret: ${AWS_SECRET_NAME} " 
    aws secretsmanager create-secret \
    --name "${AWS_SECRET_NAME}" \
    --description "ROSA token to login with the rosa commandline" \
    --secret-string "${ROSA_TOKEN}"
  fi

  AWS_SECRET_NAME="${ROSA_CLUSTER_NAME}"-cluster-admin-pwd
  AWS_SECRET_NAME_EXISTS=$(aws secretsmanager list-secrets --output json | \
          jq -r --arg SECRET_NAME "${AWS_SECRET_NAME}" '.SecretList[] | select(.Name == $SECRET_NAME ) | .Name')

  if [[ -z "${AWS_SECRET_NAME_EXISTS}" ]]; then 
    echo "Creating AWS Secrets Manager secret: ${AWS_SECRET_NAME} " 
    aws secretsmanager create-secret \
    --name "${AWS_SECRET_NAME}" \
    --description "ROSA CLUSTER: ${ROSA_CLUSTER_NAME} cluster-admin password" \
    --secret-string "WILL BE ADDED BY AUTOMATION"
  fi

}

delete_cluster() {
  rosa_login
  SECS=10800 # WAIT 3 hours in seconds.
  ENDTIME=$(( $(date +%s) + SECS ))

  ROSA_CLUSTER_ID=$(rosa list clusters -o json | jq -r --arg ROSA_CLUSTER_NAME "${ROSA_CLUSTER_NAME}" '.[] | select(.name == $ROSA_CLUSTER_NAME ) | .id')
  [[ -n "${ROSA_CLUSTER_ID}" ]] && rosa delete cluster --cluster "${ROSA_CLUSTER_NAME}" --yes;
  while [ "$(date +%s)" -lt $ENDTIME ]; do
     ROSA_CLUSTER_STATE=$(rosa list clusters -o json | jq -r --arg ROSA_CLUSTER_NAME "${ROSA_CLUSTER_NAME}" '.[] | select(.name == $ROSA_CLUSTER_NAME ) | .status.state ')
     if [[ "${ROSA_CLUSTER_STATE}" == "uninstalling" ]]; then
         echo "Cluster uninstalling, current state: ${ROSA_CLUSTER_STATE}";
         #rosa logs install --cluster=vsipcl2 --watch
     else
         break;
     fi
     sleep 60;
  done
  [[ -n "${ROSA_CLUSTER_ID}" ]] && (rosa delete operator-roles --cluster "${ROSA_CLUSTER_ID}" --mode=auto --yes || true)
  [[ -n "${ROSA_CLUSTER_ID}" ]] && (rosa delete oidc-provider --cluster "${ROSA_CLUSTER_ID}" --mode=auto --yes || true)

  aws iam list-roles --output json | jq -r '.Roles[] | select(.RoleName | startswith("\"$ROSA_CLUSTER_OPER_ROLE_PREFIX-\"")) | .RoleName' | \
    while read -r role_name ; do \
      aws iam list-attached-role-policies --role-name "${role_name}" --output json | jq -r '.AttachedPolicies[] | .PolicyArn' | \
      while read -r policy_arn; do aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" ; done ;  \
      aws iam delete-role --role-name "${role_name}" ; \
    done || true
}

check_if_cluster_exists() {
  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url')
  if [[ -n "${ROSA_CLUSTER_API_URL}" ]]; then
    echo "cluster: ${ROSA_CLUSTER_NAME} already exists"
    rosa describe cluster -c "${ROSA_CLUSTER_NAME}" --region "${ROSA_CLUSTER_REGION}" 
    return 0
  else
    echo "cluster: ${ROSA_CLUSTER_NAME} does not exists"
    return 1
  fi  
}

get_subnets_cidr_for_rosa_vpc() {
  if [[ -z "${AWS_ACCOUNT_ROSA_VPC_ID}" ]]; then 
    AWS_ACCOUNT_ROSA_VPC_ID=$(aws ec2 describe-vpcs --output json --region "${ROSA_CLUSTER_REGION}" | jq -r '.Vpcs[] | select(.Tags[].Key=="Name" and (.Tags[].Value  | contains("rosa"))) | .VpcId' | sort | uniq | head -n 1)
  fi

  if [[ -z "${ROSA_CLUSTER_MACHINE_CIDR}" ]]; then 
    ROSA_CLUSTER_MACHINE_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${AWS_ACCOUNT_ROSA_VPC_ID}" --output json --region "${ROSA_CLUSTER_REGION}" | jq -r '.Vpcs[] | select(.Tags[].Key=="Name" and (.Tags[].Value | contains("rosa"))) | .CidrBlock' | sort | uniq | head -n 1)
  fi

  SUBNETS=$(aws ec2 describe-subnets --output json --region "${ROSA_CLUSTER_REGION}" | jq -r --arg VPCId "${AWS_ACCOUNT_ROSA_VPC_ID}" '.Subnets[] | select(.VpcId==$VPCId) | .SubnetId' )
  a=( ${SUBNETS} )
  if [[ -n "${ROSA_CLUSTER_MULTI_AZ}" && ( -z "${ROSA_SUBNET1}" || -z "${ROSA_SUBNET2}" || -z "${ROSA_SUBNET3}" ) ]]; then
    NUM_SUBNETS=$(echo "${SUBNETS}" | wc -w)
    if [ "${NUM_SUBNETS}" -ge 3 ]; then
      ROSA_SUBNET1="${a[0]}"
      ROSA_SUBNET2="${a[1]}"
      ROSA_SUBNET3="${a[2]}"
    fi
  elif [[ -z "${ROSA_CLUSTER_MULTI_AZ}" && -z "${ROSA_SUBNET1}" ]]; then
    NUM_SUBNETS=$(echo "${SUBNETS}" | wc -w)
    if [ "${NUM_SUBNETS}" -gt 0 ]; then ROSA_SUBNET1="${a[0]}" ; fi
  fi
}

update_kms_policy() {
  if [[ -z "${ROSA_CLUSTER_KMS_KEY_ARN}" ]]; then return 0; fi
  ACCOUNT=$AWS_ROSA_ACCOUNT_ID

    cat <<EOF > ./keypolicy.json
{
    "Version": "2012-10-17",
    "Id": "key-rosa-policy-1",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::$ACCOUNT:root"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow ROSA use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Support-Role", 
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Allow attachment of persistent resources",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Support-Role", 
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:CreateGrant",
                "kms:ListGrants",
                "kms:RevokeGrant"
            ],
            "Resource": "*",
            "Condition": {
                "Bool": {
                    "kms:GrantIsForAWSResource": "true"
                }
            }
        }
    ]
}
EOF

  cat keypolicy.json
  aws kms put-key-policy  --key-id "${ROSA_CLUSTER_KMS_KEY_ARN}"  --region "${ROSA_CLUSTER_REGION}" --policy-name=default --policy file://keypolicy.json
}

update_kms_policy_oper_role() {
  if [[ -z "${ROSA_CLUSTER_KMS_KEY_ARN}" ]]; then return 0; fi
  ACCOUNT=$AWS_ROSA_ACCOUNT_ID

    cat <<EOF > ./keypolicy.json
{
    "Version": "2012-10-17",
    "Id": "key-rosa-policy-1",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                  "arn:aws:iam::$ACCOUNT:root", 
                  "arn:aws:iam::$ACCOUNT:role/${ROSA_CLUSTER_OPER_ROLE_PREFIX}-openshift-cluster-csi-drivers-ebs-cloud-credentia"
                ]
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow ROSA use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Support-Role", 
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Allow attachment of persistent resources",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Support-Role", 
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Installer-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-Worker-Role",
                    "arn:aws:iam::$ACCOUNT:role/ManagedOpenShift-ControlPlane-Role"
                ]
            },
            "Action": [
                "kms:CreateGrant",
                "kms:ListGrants",
                "kms:RevokeGrant"
            ],
            "Resource": "*",
            "Condition": {
                "Bool": {
                    "kms:GrantIsForAWSResource": "true"
                }
            }
        }
    ]
}
EOF

  cat keypolicy.json
  aws kms put-key-policy  --key-id "${ROSA_CLUSTER_KMS_KEY_ARN}"  --region "${ROSA_CLUSTER_REGION}" --policy-name=default --policy file://keypolicy.json
}

create_cluster() {
  rosa_login
  
  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url')

  get_subnets_cidr_for_rosa_vpc

  check_if_cluster_exists && return 0

  rosa verify quota --region="${ROSA_CLUSTER_REGION}"
  rosa verify openshift-client
  rosa create account-roles --mode auto --yes
  AWS_LB_ROLE=$(aws iam list-roles | jq -r '.Roles[] | select(.Path == "/aws-service-role/elasticloadbalancing.amazonaws.com/" ) | .RoleName ')
  [[ -z "$AWS_LB_ROLE" ]] && aws iam create-service-linked-role --aws-service-name \
    "elasticloadbalancing.amazonaws.com"

  sleep 120

  update_kms_policy

  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
  # Build up array of arguments...
  args=()
  args+=( '--cluster-name' "${ROSA_CLUSTER_NAME}"  )
  args+=( --sts )
  args+=( --role-arn arn:aws:iam::"${AWS_ACCOUNT_ID}":role/ManagedOpenShift-Installer-Role )
  args+=( --support-role-arn arn:aws:iam::"${AWS_ACCOUNT_ID}":role/ManagedOpenShift-Support-Role )
  args+=( --controlplane-iam-role arn:aws:iam::"${AWS_ACCOUNT_ID}":role/ManagedOpenShift-ControlPlane-Role )
  args+=( --worker-iam-role arn:aws:iam::"${AWS_ACCOUNT_ID}":role/ManagedOpenShift-Worker-Role )
  args+=( '--operator-roles-prefix' "${ROSA_CLUSTER_OPER_ROLE_PREFIX}" )
  [[ -n "${ROSA_CLUSTER_MULTI_AZ}" ]] && args+=( '--multi-az')
  args+=( '--region' "${ROSA_CLUSTER_REGION}" )
  args+=( '--version' "${ROSA_CLUSTER_VERSION}" )
  [[ -n "${ROSA_CLUSTER_ENABLE_AUTOSCALING}" ]] && args+=( '--enable-autoscaling' '--min-replicas' "${ROSA_CLUSTER_MIN_REPLICAS}" '--max-replicas' "${ROSA_CLUSTER_MAX_REPLICAS}" )
  args+=( '--machine-cidr' "${ROSA_CLUSTER_MACHINE_CIDR}" )
  [[ -n "${ROSA_CLUSTER_SERVICE_CIDR}" ]] && args+=( '--service-cidr' "${ROSA_CLUSTER_SERVICE_CIDR}" )
  [[ -n "${ROSA_CLUSTER_POD_CIDR}" ]] && args+=( '--pod-cidr' "${ROSA_CLUSTER_POD_CIDR}" )
  args+=( '--host-prefix' "${ROSA_CLUSTER_HOST_PREFIX}" )
  args+=( '--private-link' )
  [[ -n "${ROSA_CLUSTER_KMS_KEY_ARN}" ]] && args+=( '--kms-key-arn' "${ROSA_CLUSTER_KMS_KEY_ARN}" )
  [[ -n "${ROSA_CLUSTER_MULTI_AZ}" ]]  && args+=( '--subnet-ids' "${ROSA_SUBNET1},${ROSA_SUBNET2},${ROSA_SUBNET3}" )
  [[ -z "${ROSA_CLUSTER_MULTI_AZ}" ]]  && args+=( '--subnet-ids' "${ROSA_SUBNET1}" )
  [[ -n "${ROSA_CLUSTER_COMPUTE_MACHINE_TYPE}" ]]  && args+=( '--compute-machine-type' "${ROSA_CLUSTER_COMPUTE_MACHINE_TYPE}" )
  args+=( '--region' "${ROSA_CLUSTER_REGION}" )
  args+=( '--yes' )
  [[ -n "${ROSA_CLUSTER_CLUSTER_CREATE_DRY_RUN}" ]] && args+=( '--dry-run' )

  rosa create cluster "${args[@]}"

  [[ -n "${ROSA_CLUSTER_CLUSTER_CREATE_DRY_RUN}" ]] && return 1

  rosa create operator-roles --cluster "${ROSA_CLUSTER_NAME}" --mode=auto --yes
  sleep 30 #to avoid invalid principal for newly created operator role
  update_kms_policy_oper_role
  rosa create oidc-provider --cluster "${ROSA_CLUSTER_NAME}" --mode=auto --yes
}

wait_for_cluster_ready() {
  rosa_login
  
  SECS=10800 # WAIT 3 hours in seconds.
  ENDTIME="$(( $(date +%s) + SECS ))"

  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url')

  while [ "$(date +%s)" -lt "${ENDTIME}" ]; do
    ROSA_CLUSTER_STATE=$(rosa list clusters -o json | jq -r --arg ROSA_CLUSTER_NAME "${ROSA_CLUSTER_NAME}" '.[] | select(.name == $ROSA_CLUSTER_NAME ) | .status.state ')
    if [[ "${ROSA_CLUSTER_STATE}" == "ready" ]]; then
           rosa describe cluster -c "${ROSA_CLUSTER_NAME}" ;
           break;
    elif [[ -z "${ROSA_CLUSTER_STATE}" || "${ROSA_CLUSTER_STATE}" == "error" ]]; then
         return 1;
    else
         echo "Cluster creating, current state: ${ROSA_CLUSTER_STATE}";
         rosa logs install --cluster="${ROSA_CLUSTER_NAME}" --watch
    fi
    #sleep 300;
  done
  authorize_vpc_assoc_with_rosa_PHZ
  if [[ -n "${ROSA_CLUSTER_API_URL}" ]]; then
    echo "ROSA_CLUSTER_API_URL=$ROSA_CLUSTER_API_URL" >> "${ROSA_OUTPUT_FILE}"
  fi
}

retrieve_cluster_admin_pwd() {

  #######GET CLUSTER ADMIN PASSWORD IN SECRETS MANAGER#####
  AWS_SECRET_NAME="${ROSA_CLUSTER_NAME}"-cluster-admin-pwd
  AWS_SECRET_NAME_EXISTS=$(aws secretsmanager list-secrets --output json | \
          jq -r --arg SECRET_NAME "${AWS_SECRET_NAME}" '.SecretList[] | select(.Name == $SECRET_NAME ) | .Name')

  if [[ -z "${AWS_SECRET_NAME_EXISTS}" ]]; then 
    echo "rosa cluster admin AWS Secrets Manager secret: $AWS_SECRET_NAME does not exist" 
    return 1 
  fi

  shellopts="$-"; if [[ "${shellopts}" =~ x ]]; then set +x; fi
  ROSA_CLUSTER_ADMIN_PWD=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --output json | jq -r '.SecretString')
  ROSA_CLUSTER_ADMIN_USER="cluster-admin"

  if [[ -z "${ROSA_CLUSTER_ADMIN_USER}" || -z "${ROSA_CLUSTER_ADMIN_PWD}" ]]; then 
    echo "rosa cluster admin AWS Secrets Manager secret: $AWS_SECRET_NAME does not exist" 
    set -x
    return 1 
  fi
  set -x
}
oc_login() {
  rosa_login
  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url')
  check_domain_resolvable
  retrieve_cluster_admin_pwd 
  shellopts="$-"; if [[ "${shellopts}" =~ x ]]; then set +x; fi
  oc login "${ROSA_CLUSTER_API_URL}" --insecure-skip-tls-verify --username "${ROSA_CLUSTER_ADMIN_USER}" --password "${ROSA_CLUSTER_ADMIN_PWD}" && set -x
}

delete_cluster_admin_login() {
  rosa_login
  
  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url') 
  echo 'deleting and recreating cluster admin'; 
  rosa delete admin -c "${ROSA_CLUSTER_NAME}" --yes --region "${ROSA_CLUSTER_REGION}" || true
  # credentials may still be active for a few minutes 
  while (oc login "${ROSA_CLUSTER_API_URL}" --username "${ROSA_CLUSTER_ADMIN_USER}" --password "${ROSA_CLUSTER_ADMIN_PWD}") 
  do 
    sleep 30 
  done
  return 0
}

check_domain_resolvable() {
  ROSA_CLUSTER_API_URL=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" -o json --region "${ROSA_CLUSTER_REGION}" | jq -r '.api.url')
  ROSA_CLUSTER_API_DOMAIN=$(echo "${ROSA_CLUSTER_API_URL}" | awk -F[/:] '{print $4}' )
  nslookup "${ROSA_CLUSTER_API_DOMAIN}" || \
  ( echo 'domain not resolvable, please check if shared services VPC is associated with ROSA API and Console Private Hosted Zone' && set -x && return 1 )
}
create_cluster_admin_login() {
  rosa_login 
  check_domain_resolvable
  if oc_login ; then
    echo "cluster admin user: ${ROSA_CLUSTER_ADMIN_USER} exists and password is correct in secrets manager"
    set -x 
    return 0
  else
    set -x 
    rosa create admin -c "${ROSA_CLUSTER_NAME}" --yes --region "${ROSA_CLUSTER_REGION}" > temp 
  fi

  shellopts="$-"; if [[ "${shellopts}" =~ x ]]; then set +x; fi
  ROSA_CLUSTER_ADMIN_PWD=$(awk '/--username cluster-admin/ { print $NF}' temp)
  if [[ -z "${ROSA_CLUSTER_ADMIN_PWD}" ]]; then echo 'failed to extract cluster admin password'; cat temp ; set -x; return 1 ; fi
  sleep 180

  AWS_SECRET_NAME="${ROSA_CLUSTER_NAME}"-cluster-admin-pwd

  AWS_SECRET_NAME_EXISTS=$(aws secretsmanager list-secrets --output json | \
          jq -r --arg SECRET_NAME "${AWS_SECRET_NAME}" '.SecretList[] | select(.Name == $SECRET_NAME ) | .Name')

  if [[ -z "${AWS_SECRET_NAME_EXISTS}" ]]; then 
    echo "Creating rosa cluster admin AWS Secrets Manager secret: $AWS_SECRET_NAME "
    aws secretsmanager create-secret \
    --name "${AWS_SECRET_NAME}" \
    --description "ROSA CLUSTER: ${ROSA_CLUSTER_NAME} cluster-admin password" \
    --secret-string "${ROSA_CLUSTER_ADMIN_PWD}"
  else
    echo "Updating rosa cluster admin AWS Secrets Manager secret: $AWS_SECRET_NAME " 
    aws secretsmanager update-secret \
    --secret-id "${AWS_SECRET_NAME}" \
    --secret-string "${ROSA_CLUSTER_ADMIN_PWD}"
  fi
  
  sleep 600

  set -x

  oc_login 

  if [[ -n "${AWS_SECRET_NAME}" && -n "${ROSA_CLUSTER_ADMIN_USER}" ]]; then
    echo "ROSA_CLUSTER_ADMIN_USER=${ROSA_CLUSTER_ADMIN_USER}" >> "${ROSA_OUTPUT_FILE}"
    echo "ROSA_CLUSTER_ADMIN_PASSWORD_SECRET_NAME=$AWS_SECRET_NAME" >> "${ROSA_OUTPUT_FILE}"
  fi 
}

authorize_vpc_assoc_with_rosa_PHZ() {
  ROSA_PRIVATE_HOSTED_ZONES=
  # authorize all private host zones created by ROSA to be associated with Egress VPC
  ROSA_API_BASE_DOMAIN=$(rosa describe cluster -c "${ROSA_CLUSTER_NAME}" --region "${ROSA_CLUSTER_REGION}" --output json | jq -r '.dns.base_domain') 
  for ROSA_DEFAULT_DOMAIN_ID in $(aws route53 list-hosted-zones --output=json | jq -r --arg ROSA_API_BASE_DOMAIN "${ROSA_API_BASE_DOMAIN}" '.HostedZones[] | select(.Name | contains($ROSA_API_BASE_DOMAIN)) | .Id ' ) ;
  do
    DOMAIN_ID="${ROSA_DEFAULT_DOMAIN_ID}"
    VPC_ID="${AWS_SHARED_SERVICES_VPC_ID}" && authorize_VPC
    VPC_ID="${AWS_NETWORK_HUB_VPC_ID}" && authorize_VPC
  done
  if [[ -n "$ROSA_PRIVATE_HOSTED_ZONES" ]]; then
    ROSA_PRIVATE_HOSTED_ZONES="${ROSA_PRIVATE_HOSTED_ZONES::-1}" # removes the last comma
    echo "ROSA_PRIVATE_HOSTED_ZONES=$ROSA_PRIVATE_HOSTED_ZONES" >> $ROSA_OUTPUT_FILE
  fi 
}

authorize_VPC() {
    if [[ -z "${DOMAIN_ID}" || -z "${VPC_ID}" ]]; then echo "Either $DOMAIN_ID or $VPC_ID not specified" ; return 0 ; fi
    IS_PHZ=$(aws route53 get-hosted-zone  --id "${DOMAIN_ID}" --output json --region="${ROSA_CLUSTER_REGION}" | jq -r '.HostedZone | .Config | .PrivateZone')
    if [[ "$IS_PHZ" != "true" ]]; then echo "$VPC_ID in not a private vpc" ; return 0 ; fi
    VPC_ASSOCIATED=$(aws route53 get-hosted-zone  --id "${DOMAIN_ID}" --output json --region="${ROSA_CLUSTER_REGION}" | jq -r --arg VPC_ID "${VPC_ID}" '.VPCs[] | select(.VPCId==$VPC_ID) | .VPCId')
    if [[ -n "$VPC_ASSOCIATED" ]]; then echo "$VPC_ID is already associated" ; return 0 ; fi
    AUTH_EXISTS=$(aws route53 list-vpc-association-authorizations --hosted-zone-id "${DOMAIN_ID}" --output=json --region="${ROSA_CLUSTER_REGION}" | jq -r --arg AWS_VPC_ID "${VPC_ID}" '.VPCs[]| select(.VPCId == $AWS_VPC_ID ) .VPCId ')
    if [[ -n "${AUTH_EXISTS}" ]]; then 
      if [[ "${ROSA_PRIVATE_HOSTED_ZONES}" != *"${DOMAIN_ID}"* ]]; then 
        echo "$VPC_ID is authorized but not associated with ${DOMAIN_ID} "  
        ROSA_PRIVATE_HOSTED_ZONES="${DOMAIN_ID#/hostedzone/},${ROSA_PRIVATE_HOSTED_ZONES}" 
      fi 
      return 0  
    fi
    echo "Authorizing association for ${VPC_ID} passing ${DOMAIN_ID} for association" 
    aws route53 create-vpc-association-authorization --hosted-zone-id "${DOMAIN_ID}" --vpc VPCRegion="${ROSA_CLUSTER_REGION}",VPCId="${VPC_ID}"
    if [[ "${ROSA_PRIVATE_HOSTED_ZONES}" != *"$DOMAIN_ID"* ]]; then 
      ROSA_PRIVATE_HOSTED_ZONES="${DOMAIN_ID},${ROSA_PRIVATE_HOSTED_ZONES}" 
    fi
    return 0 
}

# take the method name as a parameter and execute method
if [[ -n "$1" ]]; then "$@" ; exit 0 ; fi

exit 0;
