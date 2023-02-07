#!/bin/bash

set -eu

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ROOT_PATH="$SCRIPT_PATH/.."

pushd "${ROOT_PATH}"

    echo -e "\n[ShellCheck]"
    find . -name "*.sh" -exec shellcheck -e SC2001 -e SC2206 -e SC2046 -e SC2129 {} \;

    echo -e "\n[LINTING]"
    cfn-lint --info "$PWD"/rosa-infrastructure/**/*.yaml -i W3002
    cfn-lint --info "$PWD"/rosa-infrastructure/**/*.json

    echo -e "\n[SECURITY-SCAN]"
    docker run --tty --volume "$PWD":/code --workdir /code bridgecrew/checkov --directory /code --skip-check CKV_DOCKER_7,CKV_DOCKER_2,CKV_AWS_111,CKV_AWS_18

popd
