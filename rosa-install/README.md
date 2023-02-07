# AWS ROSA Installation Container Infrastructure as Code

This repository includes Infrastructure as Code (IaC) to install, configure and uninstall private Red Hat OpenShift Service on AWS (ROSA) clusters in a AWS Control Tower Landing Zone (LZ) account using a Docker container. It includes:

1. **Dockerfile** : Used to create a simple docker container with the `rosa` , `aws`, `ocm`, `oc` CLI tools 
2. **rosa_install.sh** : Bash script used to install, uninstall and configure a ROSA cluster with different methods. Some of these methods are invoked from different stages of two AWS CodePipeline: 1. ROSA-Install-Pipeline 2. ROSA-UnInstall-Pipeline . The docker image built from this dockerfile by the DeployToECR CodeBuild project is deployed to a Elastic Container Registry. Instructions for how to launch this container is provided in the following section.
3. **codepipeline** : a directory with AWS CodeBuild buidspec YAML files for two AWS CodeBuild Projects: 1. Create_ROSA_Cluster 2. DeployToECR. These projects are part of the two AWS CodePipelines 
4. **rosa_cluster_clustername** : a set of directories for deployment configurations for different clusters with names as clustername: 
   1. **rosa_params.env** : An environment variable properties file containing the following set of properties correspending to the cluster with name clustername to be installed or configured. 

## Deployment configuration management for all environments

- Deployment parameters for all ROSA clusters are stored in the **rosa-install** CodeCommit git repository. 

- Each ROSA cluster has it's deployment configuration stored in a different sub-directory in this git repo. Changes made to any configuration file in a sub-directory triggers the ROSA-Install-Pipeline that targets the specific ROSA cluster as identified from the ROSA_CLUSTER_NAME parameter in the rosa_params.env file in the sub-directory identified in the git commit change. The sub-directory name is in the format rosa_cluster_\<clustername\>

- Deployment configuration for each ROSA cluster is contained in the file: rosa_params.env

- Regular Git processes (git pull, add, commit, push) should be followed to maintain or update any cluster or project specific configuration.


## Launch the ROSA-Install-Pipeline AWS CodePipeline to install a new ROSA cluster from the rosa-ssm-jumpbox EC2 Jumpbox


1. Ensure AWS Secrets Manager secret is created/updated with the latest unexpired `ROSA_TOKEN=#Your Red Hat Account Token from https://console.redhat.com/openshift/token `
```bash
    export AWS_SECRET_NAME=ROSA_TOKEN
    export ROSA_TOKEN_VALUE=<>
    aws secretsmanager create-secret \
    --name "${AWS_SECRET_NAME}" \
    --description "OpenShift Cluster Manager API token secret created from https://console.redhat.com/openshift/token , please update upon expiry" \
    --secret-string "${ROSA_TOKEN_VALUE}"
```

2. Connect via AWS Systems Session Manager (SSM) to the `rosa-ssm-jumpbox` jumpbox

3. Git clone the rosa-install CodeCommit repository if it is not there under /home/rosagitops

```bash
mkdir <your-working-directory-name>
cd <your-working-directory-name>
git clone codecommit::<your region: e.g. us-east-2>://rosa-install
```

4. Create a new sub-directory with a new `rosa_params.env` parameter files

```bash
sudo su
cd /home/rosagitops/rosa-install
git pull origin main
mkdir rosa_cluster_<new cluster name>
cd rosa_cluster_<new cluster name>
vi rosa_params.env # change ROSA_CLUSTER_NAME and other cluster specific parameters
```


6. Trigger the ROSA-Install-Pipeline

```bash
sudo su
cd /home/rosagitops/rosa-install
git add .
git commit -m "Adding new cluster: <new cluster name >"
git push origin main
```

7. Approve execution of the Rosa-Install-Pipeline and review progress of the pipeline from


## Launch the ROSA-Delete-Pipeline AWS CodePipeline to rollback/uninstall a ROSA cluster from the rosa-ssm-jumpbox EC2 Jumpbox

1. Connect via AWS Systems Session Manager (SSM) to the `rosa-ssm-jumpbox` jumpbox

2. Git clone the rosa-uninstall CodeCommit repository if it is not there under /home/rosagitops

```bash
mkdir <your-working-directory-name>
cd <your-working-directory-name>
git clone codecommit::<your region: e.g. us-east-2>://rosa-uninstall
```

2. Create a new sub-directory with a rosa_params.env specifying the cluster to delete, preferably copied from an existing rosa_params.env from the rosa-install repo

```bash
sudo su
cd /home/rosagitops/rosa-uninstall
git pull origin main
mkdir rosa_cluster_<cluster name>
cp -r ../rosa-install/rosa_cluster_<cluster name>/rosa_params.env rosa_cluster_<cluster name>/
cd rosa_cluster_<cluster name>
vi rosa_params.env # check ROSA_CLUSTER_NAME
```
3. Trigger the ROSA-Delete-Pipeline

```bash
git add .
git commit -m "Deleting cluster: <new cluster name >"
git push origin main
```

4. Approve execution of the Rosa-Delete-Pipeline and review progress of the pipeline from AWS CodePipeline

## Launch the ROSA Installation Docker container to administer an existing ROSA cluster from the rosa-ssm-jumpbox EC2 Jumpbox

1. Connect via AWS Systems Session Manager (SSM) to the `rosa-ssm-jumpbox` jumpbox

2. Pull the latest changes into your cloned repo 

```bash
sudo su
cd /home/rosagitops/rosa-install
git pull origin main
cat rosa_install.sh
cd rosa_cluster_<cluster_name>
cat rosa_params.env
```

3. Pull the latest ROSA Installation docker image

```bash
SHARED_SERVICES_ECR_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text)
REGION=us-east-2
aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker pull $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/rosa-install:latest
docker tag $SHARED_SERVICES_ECR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/rosa-install:latest rosa-install:latest
```

4. Run a bash shell in the ROSA Installation container using credentials for the session:

```bash
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_SECRET_ACCESS_TOKEN=
REGION=us-east-2
docker run --rm --env-file=rosa_params.env -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" -e ROSA_CLUSTER_REGION="$REGION" -it --entrypoint /bin/bash rosa-install:latest
```

5. Login to the openshift cluster using the cluster-admin password from secrets manager:

```bash
cd /aws
./rosa_install.sh oc_login
```

