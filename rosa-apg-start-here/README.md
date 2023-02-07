# Quick Start automation for creating private ROSA OpenShift Kubernetes clusters using a GitOps approach with AWS CodePipeline

This repository includes a bash script which creates a set of nested AWS CloudFormation stacks for installing a set of private VPCs and a CodePipeline and other AWS resources for installing and running secure private AWS ROSA (Red Hat OpenShift in AWS) clusters:

A private AWS VPC (rosa-vpc) is created for running a private-link STS ROSA cluster. The rosa-vpc is connected to a egress VPC for outgoing traffic to the internet (which is a requirement for installing ROSA). The rosa-vpc is also connected to a shared services VPC which hosts a private AWS ECR Registry for Docker images for a ROSA Installation container and a AWS CodePipeline used for installing and deleting ROSA clusters. The CodePipelines use a GitOps approach with the ROSA Installation container and configuration derived from CodeCommit repositories. A SSM connected jumpbox is provided to access the private cluster and make configuration changes through git cloned repositories available in the jumpbox. The following diagram depicts the network components and ROSA services:

![ROSA-Network](images/rosa-arch.png?raw=true "ROSA Network")


## Pre-requisites:
1. The steps listed in the main [README](../README.md) have been followed to launch the ROSA-Install-Pipeline and ROSA-Delete-Pipeline

## Install Steps:

2. Open AWS CodePipeline: `ROSA-Install-Pipeline` and review and approve the `Create-Cluster-Approval` stage. The initial commit to the AWS CodeCommit repository: `rosa-install` automatically triggers the `ROSA-Install-Pipeline`. The resultant pipeline execution remains blocked on the `Install-Cluster-Approval` stage for an explicit approval. If this pipeline execution is stopped due to a long period of inactivity it is possible to retrigger the pipeline by making a commit to the `rosa_cluster_<cluster name>/rosa-params.env` file in the `rosa-install` AWS CodeCommit repository.
![ROSA-Install-Pipeline Review](images/ROSA-Install-Pipeline-Review.png?raw=true "ROSA Install Pipeline Review")
![ROSA-Install-Pipeline Approve](images/ROSA-Install-Pipeline-Approve.png?raw=true "ROSA Install Pipeline Approve")
3. Monitor the AWS CodePipeline for successful completion, it typically takes a little more than an hour to complete all tages, if there are no failures. If there any failures, it is possible to retry any stage. All stages are idempotent.
![ROSA-Install-Pipeline Completion](images/ROSA-Install-Pipeline-Completion.png?raw=true "ROSA Install Pipeline Completion")
4. Connect to the `rosa-ssm-jumpbox` VM using AWS Systems Session Manager
![ROSA-SSM-Jumpbox](images/ROSA-SSM-Jumpbox.png?raw=true "Connect to the ROSA SSM Jumpbox")
![ROSA-SSM-Jumpbox-Connect](images/ROSA-SSM-Jumpbox-Connect.png?raw=true "Connect to the ROSA SSM Jumpbox Connect")
5. Connect to the ROSA OpenShift Cluster Manager using the rosa commandline, the cloned AWS CodeCommit repository with rosa_params.env, a utility Docker container (rosa-install) pulled from AWS Elastic Container Registry with a bash script (rosa_install.sh) with the install and uninstall functions and credentials from AWS SecretsManager
```
export REGION=<YOUR REGION e.g. us-east-2>
SHARED_SERVICES_ECR_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text)
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_SECRET_ACCESS_TOKEN=
sudo su
aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker pull $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/rosa-install:latest
docker tag $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/rosa-install:latest rosa-install:latest
cd /home/rosagitops/rosa-install/rosa_cluster_rosa1/
docker run --rm --env-file=rosa_params.env -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" -e ROSA_CLUSTER_REGION="$REGION" -it --entrypoint /bin/bash rosa-install:latest
cd /aws
./rosa_install.sh rosa_login
rosa list clusters --region $ROSA_CLUSTER_REGION
```
![rosa-login](images/rosa-login.png?raw=true "rosa login")
6. Connect to the ROSA cluster using the oc commandline and credentials from AWS SecretsManager
```
./rosa_install.sh oc_login
```
![rosa-login](images/rosa-oc-login.png?raw=true "oc login")
7. Deploy and connect to a hello openshift sample application
```
oc new-app --docker-image=docker.io/openshift/hello-openshift -n default
```
![rosa-login](images/rosa-app-deploy.png?raw=true "oc new-app")
8. Stop the Docker container by running exit. If the session times out, you can reconnect and find the running docker container by running `sudo docker ps` and stop it by running `sudo docker stop <container id>`

## Uninstall Steps:
1. Delete the ROSA cluster using the `ROSA-Delete-Pipeline`. The initial commit to the AWS CodeCommit repository `rosa-uninstall` automatically triggers the `ROSA-Delete-Pipeline`. The resultant pipeline execution remains blocked on the `Delete-Cluster-Approval` stage for an explicit approval. If this pipeline execution is stopped due to a long period of inactivity it is possible to retrigger the pipeline by making a commit to the `rosa_cluster_<cluster name>/rosa-params.env` file in the `rosa-uninstall` AWS CodeCommit repository.
![ROSA-Delete-Pipeline Review](images/ROSA-Delete-Pipeline-Review.png?raw=true "ROSA Delete Pipeline Review")
![ROSA-Delete-Pipeline Approve](images/ROSA-Delete-Pipeline-Approve.png?raw=true "ROSA Delete Pipeline Approve")
2. Monitor the AWS CodePipeline for successful completion, it typically takes about 20-30 minutes to complete all stages.
![ROSA-Delete-Pipeline Completion](images/ROSA-Delete-Pipeline-Completion.png?raw=true "ROSA Delete Pipeline Completion")


## Cleanup
2. Launch the rosa-apg-cleanup.sh script
```
cd rosa-apg-start-here
./rosa-apg-cleanup.sh 
```
