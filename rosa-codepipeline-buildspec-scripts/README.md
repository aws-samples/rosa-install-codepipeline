# AWS ROSA installation infrastructure as code CodeBuild Project buildspec scripts

This repository includes AWS CodeBuild buildspec script for building and executing a ROSA installation container. This build spec script is used in for the ROSA Installation container CodeBuild Project. It includes the following file:

- **codepipeline.sh** : 

This script identifies a specific rosa_params.env file modified in the latest commit to either the rosa-install or rosa-uninstall repo. It passes the modified rosa_params.sh as well as other input parameters from the AWS CodeBuild project to the ROSA installation container as environment variables. If no modified rosa_params.env file is found in the latest commit triggering the CodePipeline, then this scripts sets a flag in a file called rosa_input.env to indicate the ROSA installation container does not need to execute any function.

Prior to invoking the ROSA Installation Container, this script also 

1. Pulls the latest ROSA Installation Container image from the Elastic Container Registry respository.
2. Associates VPCs for shared services  and for network hub account with private hosted zones created during the execution of any prior stage of the rosa installation container
3. Assumes the ROSAInstallation role
4. Pushes any output environment file (rosa_output.env) generated during execution of the ROSA installation container for use in subsequent stages of the pipeline.

