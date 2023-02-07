ARG AWS_ECR_ACCOUNT_ID=xxxxxxxxx
ARG AWS_DEFAULT_REGION=us-east-1
ARG AWS_CLI_LOCAL_IMG=amazon/aws-cli
ARG ROSA_INSTALL_IO_ROOT_DIR=/home/rosa_install_user/rosa_install_io
FROM $AWS_ECR_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$AWS_CLI_LOCAL_IMG:mylatest

RUN yum install -y wget tar gzip gunzip which jq openssl bind-utils shadow-utils && \
    yum clean all
RUN wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz && \
    wget https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz && \
    wget https://github.com/openshift-online/ocm-cli/releases/download/v0.1.60/ocm-linux-amd64 && \
    tar xvfz openshift-client-linux.tar.gz && \
    mv oc /usr/local/bin && \
    mv kubectl /usr/local/bin && \
    tar xvfz rosa-linux.tar.gz && \ 
    mv rosa /usr/local/bin && \
    mv ocm-linux-amd64 /usr/local/bin/ocm && \ 
    chmod a+x /usr/local/bin/ocm && \
    rm *.gz && \
    which rosa && \
    which oc && \
    which kubectl && \
    which ocm

COPY ./ /aws/
RUN ls -alR && \
    chmod a+x /aws/rosa_install.sh

RUN useradd -ms /bin/bash rosa_install_user 
USER rosa_install_user
WORKDIR /home/rosa_install_user

HEALTHCHECK NONE

ENTRYPOINT ["/aws/rosa_install.sh"]
