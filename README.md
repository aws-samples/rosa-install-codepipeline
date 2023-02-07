#  Red Hat OpenShift Service on AWS: ROSA Install CodePipeline

This repository provides [AWS CloudFormation](https://aws.amazon.com/cloudformation/) templates, a Dockerfile, Bash scripts to deploy a PrivateLink Red Hat OpenShift on AWS (ROSA) cluster using a [AWS CodePipeline](https://aws.amazon.com/codepipeline/). Includes security best practices such as use of Secrets Manager, KMS, immutable ECR repository, closed security groups with temporary internet access during installation and routing egress traffic through a separate Egress VPC connected through a Transit Gateway, storage of all installation parameters and logs in CodeBuild etc.

This setup creates 3 private VPCs and subnets for deploying a PrivateLink ROSA cluster following AWS best practices. This is an end-to-end setup resulting in a functional ROSA cluster where a kubernetes application can be readily deployed as shown in [these detailed steps]( rosa-apg-start-here/README.md ) . Once deployed, pieces of this code can be used to create home grown automation.

## Pre-requisites

1. An AWS account with [Red Hat OpenShift Service on AWS Enabled](https://docs.aws.amazon.com/ROSA/latest/userguide/getting-started-private-link.html#_step_1_verify_prerequisites)
2. [Increased EC2 quota (at least 100)](https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A) 
3. [Increased Elastic Load Balancer quota (at least 50)](https://console.aws.amazon.com/servicequotas/home/services/elasticloadbalancing/quotas/L-53DA6B97) 
4. A Red Hat Account ([create one from here](https://sso.redhat.com/auth/realms/redhat-external/login-actions/registration?client_id=cloud-services&tab_id=Q4FD1r5Obps))
5. AWS CloudShell or a Linux like shell [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and [jq](https://stedolan.github.io/jq/download/0)


## Usage

1. Set credentials for AWS Account in environment variables
    ```
    export AWS_ACCESS_KEY_ID=
    export AWS_SECRET_ACCESS_KEY=
    export AWS_SESSION_TOKEN=
    ```
2. Copy OpenShift Cluster Manager API Token from [here](https://console.redhat.com/openshift/token) and created a AWS Secrets Manager secret with the name `ROSA_TOKEN` using the following commands
    ```
    export AWS_SECRET_NAME=ROSA_TOKEN
    export ROSA_TOKEN_VALUE=
    aws secretsmanager create-secret \
    --name "${AWS_SECRET_NAME}" \
    --description "OpenShift Cluster Manager API token secret created from https://console.redhat.com/openshift/token , please update upon expiry" \
    --secret-string "${ROSA_TOKEN_VALUE}"
    ```
3. Set the region for the ROSA cluster and the AWS CodePipeline resources
    ```
    aws configure set region <your region, e.g. us-east-2>
    ```
4. Install by launching the rosa-apg-kick-start.sh script
    ```
    cd rosa-apg-start-here
    ./rosa-apg-kick-start.sh 
    ```

    Note that this will kick off two AWS CodePipelines with names: "ROSA-Install-Pipeline" and "ROSA-Delete-Pipeline". However, these pipelines will wait for an explicit approval to proceed to creating/deleting the cluster respectively.
    For detailed instructions to run the pipeline for installing and uninstalling ROSA clusters, [click here]( rosa-apg-start-here/README.md )

4. Cleanup by running the rosa-apg-cleanup.sh script (after ensuring that the cluster is deleted)
    ```
    cd rosa-apg-start-here
    ./rosa-apg-cleanup.sh 
    ```

The VPC infrastructure for creating the ROSA cluster has been influenced by [this example](https://github.com/aws-samples/rosa-cloudformation).

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

For scanning code:
```
cd tests
./scans.sh
```

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
