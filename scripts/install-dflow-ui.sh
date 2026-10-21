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

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

source "$SCRIPT_DIR/helpers.sh"


# Ensure we have a value for domain
prepare_system_domain

echo "Installing dFlow UI"
helm upgrade --install dflow-ui --create-namespace -n dflow \
	--set domain="ui.$DFLOW_SYSTEM_DOMAIN" \
  "$SCRIPT_DIR/../helm-charts/chart/dflow-ui" \
  --wait
