#!/usr/bin/env bash
# Removes the old ClientRepAssist lab from soaring: minikube cluster(s), its containers
# and images, and local source checkouts. Docker itself is kept (it builds our images).
#
# Default is a DRY RUN that only prints the plan. Nothing is deleted without --yes:
#   bash scripts/k3s/run.sh 10-remove-clientrepassist.sh          # plan only
#   bash scripts/k3s/run.sh 10-remove-clientrepassist.sh --yes    # do it
#
# Safety: a git checkout is deleted only if it has no uncommitted changes and no
# commits missing from GitHub. Anything else is skipped and reported.
set -euo pipefail

APPLY=${1:-}
REMOTE_PATTERN='clientAssistApp'
NAME_PATTERN='clientassist|client-rep|clientrep|api-gateway|consent-service|recording-service|product-lookup-service'

# 1. git checkouts of the ClientRepAssist repo
SAFE=(); SKIP=()
while IFS= read -r gitdir; do
  repo=$(dirname "$gitdir")
  url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  [[ "$url" =~ $REMOTE_PATTERN ]] || continue
  if ! git -C "$repo" fetch --quiet origin; then SKIP+=("$repo (cannot reach GitHub to verify)"); continue; fi
  dirty=$(git -C "$repo" status --porcelain)
  unpushed=$(git -C "$repo" log --branches --not --remotes --oneline)
  if [[ -z "$dirty" && -z "$unpushed" ]]; then SAFE+=("$repo"); else SKIP+=("$repo (uncommitted or unpushed work)"); fi
done < <(find "$HOME" -maxdepth 4 -type d -name .git -not -path '*/otel-implementation/*' 2>/dev/null)

# 2. containers and images
CONTAINERS=$(docker ps -a --format '{{.Names}}' | grep -Ei "^minikube$|$NAME_PATTERN" || true)
IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Ei "$NAME_PATTERN|kicbase|gcr.io/k8s-minikube" || true)

echo "================ PLAN ================"
echo "minikube:            $(command -v minikube >/dev/null && echo 'delete all profiles (--purge), remove binary and ~/.minikube' || echo 'not installed')"
echo "containers:          ${CONTAINERS:-none}" | paste -sd' '
echo "images:              ${IMAGES:-none}" | paste -sd' '
for d in "${SAFE[@]}"; do echo "delete checkout:     $d (fully on GitHub)"; done
for d in "${SKIP[@]}"; do echo "SKIP checkout:       $d"; done
echo "kubeconfig:          $( [[ -f $HOME/.kube/config ]] && echo 'move ~/.kube/config to ~/.kube/config.minikube.bak' || echo 'none')"
echo "======================================"

if [[ "$APPLY" != "--yes" ]]; then
  echo "Dry run only. Re-run with --yes to apply."
  exit 0
fi

if command -v minikube >/dev/null; then
  minikube delete --all --purge || true
  sudo rm -f "$(command -v minikube)"
fi
rm -rf "$HOME/.minikube"
if [[ -n "$CONTAINERS" ]]; then echo "$CONTAINERS" | xargs -r docker rm -f; fi
if [[ -n "$IMAGES" ]]; then echo "$IMAGES" | xargs -r docker rmi -f; fi
docker system prune -f
for d in "${SAFE[@]}"; do rm -rf "$d"; done
if [[ -f "$HOME/.kube/config" ]]; then mv "$HOME/.kube/config" "$HOME/.kube/config.minikube.bak"; fi

free -h
df -h /
