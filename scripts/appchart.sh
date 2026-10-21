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

# Use this script to package a development version of the dflow-application helm chart, and
# then run a local nginx container attached to the dflow-acceptance network serving this chart,
# and lastly patch the standard dflow appchart in the active dFlow installation to use this version.

VERSION=0.0.0
TARBALL=dflow-application-$VERSION.tgz

echo "Packaging dflow-application chart"
helm package --version $VERSION helm-charts/chart/application

CONTAINER_ID=$(docker ps --filter name=nginx -qa)

if [ -z "$CONTAINER_ID" ]; then
    echo "Nginx is not running. Starting container"
    docker run -it -d --rm --name nginx \
        --network dflow-acceptance \
        -v $PWD/$TARBALL:/usr/share/nginx/html/$TARBALL \
        nginx
else
    echo "Nginx container already running (id: $CONTAINER_ID)"
fi

NGINX_IP=$(docker network inspect dflow-acceptance | \
    jq -r '.[].Containers[] | select(.Name=="nginx").IPv4Address' | \
    cut -d'/' -f1)

echo "Nginx internal ip: $NGINX_IP (dflow-acceptance network)"

echo "Patching appchart"

now=$(date +%s)

kubectl patch appchart -n dflow standard --type json \
    --patch '[{"op": "replace", "path": "/spec/helmChart", "value": "http://'$NGINX_IP'/'$TARBALL'?t='$now'"}]'

echo "To stop the Nginx container just run 'docker stop nginx'"
