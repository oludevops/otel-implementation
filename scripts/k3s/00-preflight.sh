#!/usr/bin/env bash
# Read-only checks of soaring before anything changes. Safe to run any time.
set -uo pipefail

hostname
cat /etc/os-release | grep -E '^(NAME|VERSION)='
nproc
free -h
df -h / /var
getenforce
systemctl is-active firewalld || true
ip -o -4 addr show | awk '{print $2, $4}'
ip route show default

docker version --format 'docker {{.Server.Version}}' || echo "docker: not available"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' || true
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | sort || true

command -v minikube && minikube profile list || echo "minikube: not installed"
command -v k3s && k3s --version || echo "k3s: not installed"
command -v kubectl && kubectl version --client || echo "kubectl: not installed"
ls -la ~/.kube 2>/dev/null || echo "$HOME/.kube: none"

# ports k3s / ServiceLB will need
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(80|443|6443|10250) /'
