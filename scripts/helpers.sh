#!/bin/bash
# Copyright © 2021 - 2023 SUSE LLC
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

function prepare_system_domain {
  echo "Prepare system domain"
  if [[ -z "${DFLOW_SYSTEM_DOMAIN}" ]]; then
    echo -e "\e[32mDFLOW_SYSTEM_DOMAIN not set. Trying to use a magic domain...\e[0m"
    DFLOW_CLUSTER_IP=$(docker inspect k3d-dflow-acceptance-server-0 | jq -r '.[0]["NetworkSettings"]["Networks"]["k3d-dflow-acceptance"]["IPAddress"]')
    if [[ -z $DFLOW_CLUSTER_IP ]]; then
      echo "Couldn't find the cluster's IP address"
      exit 1
    fi

    export DFLOW_SYSTEM_DOMAIN="${DFLOW_CLUSTER_IP}.sslip.io"
    
  fi
  if [[ "${DFLOW_PORT}" ]]; then
      export DFLOW_DOMAIN_AND_PORT="${DFLOW_SYSTEM_DOMAIN}:${DFLOW_PORT}"
  else
      export DFLOW_DOMAIN_AND_PORT="${DFLOW_SYSTEM_DOMAIN}"
  fi
  # export DFLOW_SYSTEM_DOMAIN="127.0.0.1.sslip.io"
  echo -e "Using \e[32m${DFLOW_SYSTEM_DOMAIN}\e[0m for dFlow domain"
  echo -e "Using \e[32m${DFLOW_PORT}\e[0m for dFlow port"
  echo -e "Will attempt to use https://dflow.$DFLOW_DOMAIN_AND_PORT for login"
}

