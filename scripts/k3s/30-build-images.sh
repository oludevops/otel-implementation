#!/usr/bin/env bash
# Builds the 11 Online Boutique images from this repo and imports them into k3s's
# containerd (single node, so no registry is needed). Tags match deploy/k3s.
set -euo pipefail
cd "$(dirname "$0")/../.."

TAG=virgin
# sudo on CentOS/RHEL does not search /usr/local/bin, so use the full path
K3S=$(command -v k3s)
SERVICES=(adservice cartservice checkoutservice currencyservice emailservice frontend
          loadgenerator paymentservice productcatalogservice recommendationservice shippingservice)

# test images left over from the clean-up phase
# (grep finds nothing once they are gone; that is not an error)
docker images --format '{{.Repository}}:{{.Tag}}' | { grep '^ob-virgin/' || true; } | xargs -r docker rmi

git log --oneline -1
for svc in "${SERVICES[@]}"; do
  ctx="src/$svc"
  [[ "$svc" == cartservice ]] && ctx="src/cartservice/src"
  docker build --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" -t "ob/$svc:$TAG" "$ctx"
  docker save "docker.io/ob/$svc:$TAG" | sudo "$K3S" ctr images import -
done

# every image must now be in k3s's containerd
in_k3s=$(sudo "$K3S" ctr images ls -q)
grep ":$TAG$" <<<"$in_k3s" || true
missing=0
for svc in "${SERVICES[@]}"; do
  grep -qx "docker.io/ob/$svc:$TAG" <<<"$in_k3s" || { echo "MISSING in k3s: ob/$svc:$TAG"; missing=$((missing + 1)); }
done
echo "images in k3s: $(( ${#SERVICES[@]} - missing )) of ${#SERVICES[@]}"
(( missing == 0 ))
