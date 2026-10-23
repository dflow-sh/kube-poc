#!/usr/bin/env bash
# Local smoke: k3d, chart install, container-image push, list, logs, delete.
# Reaches the API through kubectl port-forward. See docs/INSTALL.md for a VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-dflow}"
DOMAIN="${DOMAIN:-127.0.0.1.sslip.io}"
IMAGE="${IMAGE:-ghcr.io/dflow-sh/dflow-server:v0.0.0-dev}"
PASSWORD="${PASSWORD:-password}"
NS="${NS:-sample}"
APP="${APP:-hello}"
SAMPLE_IMAGE="${SAMPLE_IMAGE:-traefik/whoami}"
export PATH="/usr/local/go/bin:${PATH}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing $1" >&2
    exit 1
  }
}

need docker
need k3d
need helm
need kubectl
need go

echo "== build CLI =="
mkdir -p "${ROOT}/apps/cli/dist"
CGO_ENABLED=0 go build -o "${ROOT}/apps/cli/dist/dflow" "${ROOT}/apps/cli"
DFLOW="${ROOT}/apps/cli/dist/dflow"

echo "== image =="
docker build -f "${ROOT}/images/Dockerfile" -t "${IMAGE}" "${ROOT}"

if ! k3d cluster list -o json | grep -q "\"${CLUSTER}\""; then
  echo "== k3d cluster ${CLUSTER} =="
  k3d cluster create "${CLUSTER}" \
    --k3s-arg "--flannel-backend=host-gw@server:*" \
    --k3s-arg "--disable=metrics-server@server:*" \
    --k3s-arg "--tls-san=127.0.0.1@server:*" \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --wait
fi

# k3d writes the API server as 0.0.0.0, which is not a usable client address.
export KUBECONFIG="${KUBECONFIG_OUT:-/tmp/dflow-k3d.kubeconfig}"
k3d kubeconfig get "${CLUSTER}" > "${KUBECONFIG}"
sed -i 's/0.0.0.0/127.0.0.1/' "${KUBECONFIG}"
kubectl get nodes

echo "== import server image =="
k3d image import "${IMAGE}" -c "${CLUSTER}"

echo "== cert-manager =="
# Certificate manifests in the dFlow chart cannot be applied in the same
# Helm release that first installs the cert-manager CRDs.
helm upgrade --install cert-manager "${ROOT}/packages/helm-chart/charts/cert-manager-v1.19.3.tgz" \
  --namespace cert-manager --create-namespace \
  --values "${ROOT}/packages/helm-chart/cert-manager-images.yaml" \
  --set crds.enabled=true \
  --timeout 10m
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=10m
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m

echo "== helm install =="
helm upgrade --install dflow "${ROOT}/packages/helm-chart" \
  --namespace dflow --create-namespace \
  --set global.domain="${DOMAIN}" \
  --set certManager.install=false \
  --set certManager.enabled=true \
  --set dflowUI.enabled=false \
  --set api.adminPassword="${PASSWORD}" \
  --timeout 15m

kubectl -n dflow rollout status deploy/dflow-server --timeout=15m
kubectl -n dflow get pods

echo "== port-forward =="
# Login speaks TLS. Forward Traefik's HTTPS port. k3s ServiceLB may stay
# unready on kernels without the iptables multiport match; the NodePort
# path through this forward still reaches the API.
kubectl -n kube-system port-forward svc/traefik 18443:443 >/tmp/dflow-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT
API="https://dflow.${DOMAIN}:18443"
for _ in $(seq 1 30); do
  if curl -sk -o /dev/null "${API}/ready"; then
    break
  fi
  sleep 2
done
curl -sk "${API}/ready" >/dev/null

export DFLOW_SETTINGS="${ROOT}/.e2e-settings.yaml"
rm -f "${DFLOW_SETTINGS}"

echo "== login =="
"${DFLOW}" login --trust-ca -u admin -p "${PASSWORD}" "${API}"

echo "== namespace =="
"${DFLOW}" namespace create "${NS}" || true
"${DFLOW}" target "${NS}"

echo "== push =="
"${DFLOW}" push -n "${APP}" --container-image-url "${SAMPLE_IMAGE}"

echo "== list =="
"${DFLOW}" app list

echo "== logs =="
"${DFLOW}" app logs "${APP}" || true

echo "== delete =="
"${DFLOW}" app delete "${APP}"

echo "smoke ok"
