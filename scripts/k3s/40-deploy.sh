#!/usr/bin/env bash
# Deploys Online Boutique to k3s from the deploy/k3s overlay and waits for it.
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
NS=online-boutique

kubectl kustomize deploy/k3s | grep -E '^kind:|image:' | sort | uniq -c
kubectl apply -k deploy/k3s
kubectl -n "$NS" wait --for=condition=Available deployment --all --timeout=600s
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get svc
