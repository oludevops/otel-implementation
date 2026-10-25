#!/usr/bin/env bash
# Installs single-node k3s on soaring (CentOS Stream 10).
#  - node bound to the host-only IP so the shop is reachable from Windows
#  - Traefik disabled: k3s's built-in ServiceLB serves frontend-external on port 80
#  - firewalld, NetworkManager and SELinux prepared per the k3s docs for RHEL-family hosts
set -euo pipefail

NODE_IP=${NODE_IP:-192.168.56.111}
CLUSTER_NAME=soaring-k3s
K3S_VERSION=${K3S_VERSION:-}   # empty = current stable channel

IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2}')
[[ -n "$IFACE" ]] || { echo "No interface has $NODE_IP; set NODE_IP=..."; exit 1; }

# Refuse to install over an existing cluster that still runs workloads, unless told to.
if systemctl is-active --quiet k3s && [[ "${1:-}" != "--allow-existing" ]]; then
  others=$(sudo "$(command -v k3s)" kubectl get ns -o name | grep -vE 'namespace/(default|kube-system|kube-public|kube-node-lease|online-boutique)$' || true)
  if [[ -n "$others" ]]; then
    echo "k3s is already running here with these namespaces:"; echo "$others"
    echo "Remove them first, or re-run with --allow-existing to upgrade k3s in place."
    exit 1
  fi
fi

# firewalld: API server, ServiceLB port 80, and trust pod/service CIDRs
if systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-port=6443/tcp
  sudo firewall-cmd --permanent --add-port=80/tcp
  sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
  sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
  sudo firewall-cmd --reload
fi

# NetworkManager must not manage the CNI interfaces
sudo tee /etc/NetworkManager/conf.d/k3s.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:cni0;interface-name:flannel*;interface-name:veth*
EOF
sudo systemctl reload NetworkManager

INSTALL_K3S_EXEC="server --node-ip=$NODE_IP --node-external-ip=$NODE_IP --flannel-iface=$IFACE \
 --tls-san=$NODE_IP --tls-san=soaring --disable=traefik --write-kubeconfig-mode=600"

curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
if ! INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" sh /tmp/k3s-install.sh; then
  # k3s-selinux may not be published for EL10 yet: use the distro's container-selinux policy
  sudo dnf -y install container-selinux
  INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" \
    INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_SELINUX_WARN=true sh /tmp/k3s-install.sh
fi
rm -f /tmp/k3s-install.sh

# kubeconfig for the current user, context named after the cluster
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG=$HOME/.kube/config
grep -q 'KUBECONFIG=' "$HOME/.bashrc" || echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
kubectl config rename-context default "$CLUSTER_NAME" || true

kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide
kubectl -n kube-system wait --for=condition=Available deployment --all --timeout=300s
kubectl get pods -A
