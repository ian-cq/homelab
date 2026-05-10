#!/usr/bin/env bash
# bootstrap.sh — Deploy k3s + ArgoCD + monitoring stack to quanianitis-01
#
# Prerequisites (on quanianitis-01):
#   - Debian 12 installed, SSH accessible via Tailscale as quanianitis-01
#   - NVIDIA driver installed (nvidia-smi works)
#   - NVIDIA Container Toolkit installed
#   - containerd configured with nvidia runtime
#
# Prerequisites (on laptop):
#   - ansible, kubectl, helm on PATH
#   - K3S_TOKEN env var set (or remove token line from inventory.yml)
#   - SSH key auth to quanianitis@quanianitis-01
#
# Usage:
#   export K3S_TOKEN=$(openssl rand -base64 64)
#   ./bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
K3S_DIR="$REPO_ROOT/k3s"
INFRA_DIR="$REPO_ROOT/infra/kustomize"

echo "=== Step 1: Install k3s via Ansible ==="
pushd "$K3S_DIR" > /dev/null
ansible-playbook playbooks/site.yml -i inventory.yml
popd > /dev/null

echo ""
echo "=== Step 2: Verify k3s node ==="
kubectl config use-context quanianitis
kubectl get nodes -o wide
echo ""

echo "=== Step 3: Wait for node to be Ready ==="
kubectl wait --for=condition=Ready node --all --timeout=120s
echo ""

echo "=== Step 4: Deploy NVIDIA device plugin ==="
kubectl apply -k "$INFRA_DIR/nvidia-device-plugin/"
echo "Waiting for nvidia-device-plugin daemonset to be ready..."
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=120s || true
echo ""

echo "=== Step 5: Install ArgoCD (minimal) ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Use kustomize to render and apply
kubectl kustomize "$INFRA_DIR/argocd/" --enable-helm | kubectl apply -f -
echo "Waiting for ArgoCD server to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
echo ""

echo "=== Step 6: Deploy Prometheus ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize "$INFRA_DIR/prometheus/" --enable-helm | kubectl apply -f -
echo "Waiting for Prometheus server..."
kubectl -n monitoring rollout status deployment/prometheus-server --timeout=180s || true
echo ""

echo "=== Step 7: Deploy Node Exporter ==="
kubectl kustomize "$INFRA_DIR/node-exporter/" --enable-helm | kubectl apply -f -
echo "Waiting for node-exporter daemonset..."
kubectl -n monitoring rollout status daemonset/node-exporter-prometheus-node-exporter --timeout=120s || true
echo ""

echo "=== Step 8: Deploy Grafana ==="
kubectl kustomize "$INFRA_DIR/grafana/" --enable-helm | kubectl apply -f -
echo "Waiting for Grafana..."
kubectl -n monitoring rollout status deployment/grafana --timeout=180s || true
echo ""

echo "=== Step 9: CUDA GPU smoke test ==="
kubectl delete pod cuda-smi --ignore-not-found=true
kubectl apply -f "$INFRA_DIR/nvidia-device-plugin/cuda-test-pod.yaml"
echo "Waiting for CUDA pod to complete..."
kubectl wait --for=condition=Ready pod/cuda-smi --timeout=120s 2>/dev/null || true
sleep 5
kubectl logs cuda-smi 2>/dev/null || echo "(pod may still be starting — check with: kubectl logs cuda-smi)"
echo ""

echo "=== Deployment Summary ==="
echo ""
echo "k3s cluster:"
kubectl get nodes -o wide
echo ""
echo "All pods:"
kubectl get pods -A
echo ""
echo "--- Access ---"
echo "ArgoCD UI:  http://quanianitis-01:30080"
echo "  Username: admin"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Grafana UI: http://quanianitis-01:31000"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Prometheus: kubectl -n monitoring port-forward svc/prometheus-server 9090:80"
echo ""
echo "CUDA test:  kubectl logs cuda-smi"
echo ""
echo "=== Done ==="
