#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-dashboard-e2e}"
IMAGE_TAG="${IMAGE_TAG:-volcano-dashboard-e2e:local}"
VOLCANO_INSTALLER_URL="${VOLCANO_INSTALLER_URL:-https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml}"
CLEANUP_CLUSTER="${CLEANUP_CLUSTER:-1}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-18080}"

cleanup() {
    if [[ "${CLEANUP_CLUSTER}" == "1" ]]; then
        kind delete cluster --name "${CLUSTER_NAME}" || true
    fi
}

if [[ "${CLEANUP_CLUSTER}" == "1" ]]; then
    trap cleanup EXIT
fi

echo "Creating Kind cluster ${CLUSTER_NAME}..."
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT}/hack/e2e-kind-config.yaml" --wait 120s

echo "Installing Volcano..."
kubectl apply -f "${VOLCANO_INSTALLER_URL}"
kubectl -n volcano-system rollout status deploy/volcano-controllers --timeout=300s
kubectl -n volcano-system rollout status deploy/volcano-scheduler --timeout=300s
kubectl -n volcano-system rollout status deploy/volcano-admission --timeout=300s

echo "Building dashboard image ${IMAGE_TAG}..."
docker build -f "${ROOT}/deployment/Dockerfile" -t "${IMAGE_TAG}" "${ROOT}"

echo "Loading dashboard image into Kind..."
kind load docker-image "${IMAGE_TAG}" --name "${CLUSTER_NAME}"

echo "Deploying volcano dashboard..."
kubectl create ns volcano-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${ROOT}/deployment/volcano-dashboard.yaml"
kubectl -n volcano-system set image deploy/volcano-dashboard \
    volcano-dashboard="${IMAGE_TAG}"
kubectl -n volcano-system rollout status deploy/volcano-dashboard --timeout=300s

echo "Installing sample cluster resources..."
kubectl apply -f "${ROOT}/examples/cluster-samples/"

echo "Waiting for sample resources to appear..."
for attempt in $(seq 1 30); do
    queue_count="$(kubectl get queues.scheduling.volcano.sh 2>/dev/null | grep -c demo- || true)"
    job_count="$(kubectl get jobs.batch.volcano.sh -A 2>/dev/null | grep -c demo- || true)"
    if [[ "${queue_count}" -ge 3 && "${job_count}" -ge 2 ]]; then
        break
    fi
    sleep 2
    if [[ "${attempt}" -eq 30 ]]; then
        echo "Sample resources did not become ready in time" >&2
        kubectl get queues.scheduling.volcano.sh || true
        kubectl get jobs.batch.volcano.sh -A || true
        exit 1
    fi
done

echo "Running dashboard smoke test..."
kubectl -n volcano-system port-forward svc/volcano-dashboard "${PORT_FORWARD_PORT}:80" >/tmp/dashboard-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!

cleanup_all() {
    if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
    cleanup
}

trap cleanup_all EXIT

for attempt in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT_FORWARD_PORT}/" >/tmp/dashboard-home.html; then
        break
    fi
    sleep 2
    if [[ "${attempt}" -eq 30 ]]; then
        echo "Dashboard did not become reachable on port ${PORT_FORWARD_PORT}" >&2
        cat /tmp/dashboard-port-forward.log >&2 || true
        exit 1
    fi
done

if ! grep -qi "volcano" /tmp/dashboard-home.html; then
    echo "Dashboard home page did not contain expected content" >&2
    head -c 500 /tmp/dashboard-home.html >&2 || true
    exit 1
fi

echo "Dashboard smoke test passed."

bash "${ROOT}/hack/smoke-test-dashboard.sh"
