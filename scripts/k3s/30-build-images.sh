#!/usr/bin/env bash
# Builds the 11 Online Boutique images from this repo and imports them into k3s's
# containerd (single node, so no registry is needed). Tags match deploy/k3s.
set -euo pipefail
cd "$(dirname "$0")/../.."

TAG=virgin
SERVICES=(adservice cartservice checkoutservice currencyservice emailservice frontend
          loadgenerator paymentservice productcatalogservice recommendationservice shippingservice)

# test images left over from the clean-up phase
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ob-virgin/' | xargs -r docker rmi

git log --oneline -1
for svc in "${SERVICES[@]}"; do
  ctx="src/$svc"
  [[ "$svc" == cartservice ]] && ctx="src/cartservice/src"
  docker build --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" -t "ob/$svc:$TAG" "$ctx"
  docker save "docker.io/ob/$svc:$TAG" | sudo k3s ctr images import -
done

sudo k3s ctr images ls -q | grep '^docker.io/ob/'
