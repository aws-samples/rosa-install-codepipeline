AWS ROSA Un-Installation Infrastructure as Code
This repository includes Infrastructure as Code (IaC) environment to create AWS resources necessary to install a private ROSA cluster securely in a private.

1. `rosa-install.yaml` : This is a root CFN stack which creates other nested stacks for other CFN resources
2. `rosa-vpcs.yaml`: Creates 3 private VPCs connected with a transit gateway 1. rosa-vpc for installing private ROSA clusters 2. Egress VPC for egress traffic 3. shared-services VPC for a CodePipeline to install and uninstall ROSA clusters
3. `rosa-install-container-role.json`: Install a ROSA Installation IAM Role with adequate least priviled permissions to install a ROSA cluster and a KMS key for cluster creation resources.
4. `rosa-install-codebuild-ec2-role.json`: Install two roles for use by the ROSA Installation CodePipeline stages and for use by a SSM Jumpbox for working with the private ROSA cluster
5. `rosa-install-assume-role.json`: Gives permission to the CodeBuild role to assume the Installation IAM Role
6. `rosa-install-ssm-ec2.json`: installs a ROSA SSM jumpbox for working with the private ROSA cluster
7. `rosa-install-codepipeline.json`: installs a AWS CodePipeline for installing ROSA clusters

