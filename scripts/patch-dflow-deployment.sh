#!/usr/bin/env bash
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

timeout=480s

# This script should be used while doing development on dFlow.
# When installing dflow, Helm will try to apply this file:
# assets/embedded-files/dflow/server.yaml . This file assumes an image
# with the current binary has been built and pushed to Dockerhub. While developing
# though, we don't always build and push such an image so the deployment will fail.
# By calling `make patch-dflow-deployment` (which calls this script), we
# fix the deployment as this:
# - We use an image that exists (the base image used when building the final image)
# - We create a PVC and a dummy pod that mounts that PVC.
# - We copy the built binary on the PVC by calling `kubectl cp` on the dummy pod.
# - We mount the same PVC on the dflow server deployment at the location where
#   the binary is expected.
# Patching the deployment forces the pod to restart with a now existing image
# and the correct binary is in place.

export DFLOW_BINARY_PATH="${DFLOW_BINARY_PATH:-dist/dflow-linux-amd64}"
export DFLOW_BINARY_TAG="${DFLOW_BINARY_TAG:-$(git describe --tags)}"
export DFLOW_NAMESPACE="${DFLOW_NAMESPACE:-dflow}"

echo
echo Configuration
echo "  - Binary:    ${DFLOW_BINARY_PATH}"
echo "  - Tag:       ${DFLOW_BINARY_TAG}"
echo "  - Namespace: ${DFLOW_NAMESPACE}"
echo

if ! kubectl get namespace "$DFLOW_NAMESPACE" >/dev/null 2>&1; then
  echo "Error: Namespace '$DFLOW_NAMESPACE' does not exist."
  echo "Please ensure dFlow is installed in this namespace before running this script."
  exit 1
fi

if ! kubectl get deployment -n "$DFLOW_NAMESPACE" dflow-server >/dev/null 2>&1; then
  echo "Error: Deployment 'dflow-server' not found in namespace '$DFLOW_NAMESPACE'."
  echo "Please ensure dFlow is installed in this namespace before running this script."
  exit 1
fi

if [ ! -f "$DFLOW_BINARY_PATH" ]; then
  echo "dflow binary path is not a file"
  exit 1
fi

if [ -z "$DFLOW_BINARY_TAG" ]; then
  echo "dflow binary tag is empty"
  exit 1
fi

echo "Creating the PVC"
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dflow-binary
  namespace: ${DFLOW_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 150Mi
EOF

echo "Creating the dummy copier Pod"
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Pod
metadata:
  name: dflow-copier
  namespace: ${DFLOW_NAMESPACE}
  annotations:
    linkerd.io/inject: disabled
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - dflow-server
        topologyKey: kubernetes.io/hostname
  volumes:
    - name: dflow-binary
      persistentVolumeClaim:
        claimName: dflow-binary
  containers:
    - name: copier
      image: busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
      command: ["/bin/sh", "-ec", "trap : TERM INT; sleep infinity & wait"]
      volumeMounts:
        - mountPath: "/dflow"
          name: dflow-binary
EOF

echo "Waiting for dummy pod to be ready"
kubectl wait --for=condition=ready --timeout=$timeout pod -n ${DFLOW_NAMESPACE} dflow-copier

echo "Copying the binary on the PVC"
# Notes
# 1. kubectl cp breaks because of the colon in `pod:path`. Thus the more complex tar construction.
# 2. Cannot use absolute paths, i.e. `/foo`. This is a disk-relative path on Windows, and gets
#    expanded weirdly by the kubectl commands.
#    Relative paths are ok, as the default CWD in the container is the root (`/`).
#    I.e. `foo` is `/foo` pod-side.

( cd       "$(dirname  "${DFLOW_BINARY_PATH}")"
  tar cf - "$(basename "${DFLOW_BINARY_PATH}")"
) | kubectl exec -i -n ${DFLOW_NAMESPACE} -c copier dflow-copier -- tar xf -
kubectl exec -i -n ${DFLOW_NAMESPACE} -c copier dflow-copier -- mv "$(basename "${DFLOW_BINARY_PATH}")" dflow/dflow
kubectl exec -i -n ${DFLOW_NAMESPACE} -c copier dflow-copier -- chmod ugo+x dflow/dflow
kubectl exec -i -n ${DFLOW_NAMESPACE} -c copier dflow-copier -- ls -l dflow

echo "Deleting the dflow-copier to avoid multi-attach issue between pods"
kubectl delete pod -n ${DFLOW_NAMESPACE} dflow-copier

# On Windows the shasum command is not in the path
[[ $(uname -s) =~ "MINGW64_NT" ]] && SHASUM=/bin/core_perl/shasum

# https://stackoverflow.com/a/5773761
DFLOW_BINARY_HASH=($(${SHASUM:=shasum} ${DFLOW_BINARY_PATH}))

helper=""
if [ -n "$GOCOVERDIR" ]; then
  helper=',{"name": "tools", "image": "alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a", "command": ["/bin/sh", "-ec", "trap : TERM INT; sleep infinity & wait"], "volumeMounts": [{"mountPath": "/tmp", "name": "tmp-volume"}]}'
fi

# Due to PV Multi-Attach Error on AKS the RollingUpdate strategy is needed.
# It will remove the original dflow-server pod immediatelly after patching.
# Note: Scaling deployment to 0 replicas and then back to 1 after patching would work similarly.
# Ref. https://github.com/andyzhangx/demo/blob/master/issues/azuredisk-issues.md#25-multi-attach-error
echo "Patching the dflow-server deployment to use the copied binary"
PATCH=$(cat <<EOF
{ "spec": { "template": {
      "metadata": {
        "annotations": {
          "binary-hash": "${DFLOW_BINARY_HASH}"
        }
      },
      "spec": {
        "volumes": [
        {
          "name":"dflow-binary",
          "persistentVolumeClaim": {
            "claimName": "dflow-binary"
          }
        }],
        "containers": [{
          "name": "dflow-server",
          "image": "ghcr.io/dflow-sh/dflow-server:v0.0.4@sha256:6bd9a740ceb0e56d014de9c94578c89daf943aadd7ee26101e71bf0ff976d8b8",
          "command": [
            "/dflow-binary/dflow",
            "server"
          ],
          "volumeMounts": [
            {
              "name": "dflow-binary",
              "mountPath": "/dflow-binary"
            }
          ]
        }$helper]
      }
    },
    "strategy": {
      "rollingUpdate": {
        "maxSurge": 0,
        "maxUnavailable": 1
      },
      "type": "RollingUpdate"
    }
  }
}
EOF
)

kubectl patch deployment -n ${DFLOW_NAMESPACE} dflow-server -p "${PATCH}"

# https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-status-em-
echo "Waiting for the rollout of the deployment to complete"
kubectl rollout status deployment -n ${DFLOW_NAMESPACE} dflow-server  --timeout=$timeout
