# AWS ROSA Un-Installation Infrastructure as Code

This repository includes Infrastructure as Code (IaC) environment property files to identify a private Red Hat OpenShift Service on AWS (ROSA) cluster in a AWS Control Tower Landing Zone (LZ) account to *uninstall*. It includes:

3. **codepipeline** : a directory with AWS CodeBuild buidspec YAML files for a AWS CodeBuild Projects: RunROSAInstallationContainer 
4. **rosa_cluster_clustername** : a set of directories for different clusters with names as clustername, directory name prefix must be *rosa_cluster_*: 
  1. **rosa_params.env** : An environment variable properties file containing the following set of properties correspending to the cluster with name clustername to be uninstalled. 


## Launch the ROSA-Delete-Pipeline AWS CodePipeline to delete an existing ROSA cluster from a jumpbox VM

1. SSM connect into jump box in ROSA account 

2. Clone the rosa-uninstall CodeCommit repos for the first time or pull latest code if already cloned and look through the latest installation code

```bash
sudo su
mkdir <your-working-directory-name e.g. /home/rosagitops>
cd <your-working-directory-name>
git clone codecommit::<your regions e.g. us-east-1>://rosa-uninstall
```

4. Create a new sub-directory with the rosa_params.env for the cluster to be deleted

```bash
sudo su
cd /home/rosagitops/rosa-uninstall
git pull origin main
mkdir rosa_cluster_<cluster name of cluster to be deleted>
cp ../rosa-install/rosa_cluster_<cluster name of cluster to be deleted>/rosa_params.env rosa_cluster_<cluster name of cluster to be deleted>
cd rosa_cluster_<cluster name of cluster to be deleted>
vi rosa_params.env # ensure that ROSA_CLUSTER_NAME is correct
git add .
git commit -m "Deleting cluster: <new cluster name >"
git push origin main
```

5. Approve execution of the Rosa-Delete_Pipeline and review progress of the pipeline from [AWS CodePipeline](https://us-east-1.console.aws.amazon.com/codesuite/codepipeline/pipelines?region=us-east-1)

