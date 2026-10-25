#!/usr/bin/env bash
# Removes what earlier labs left inside the k3s cluster on soaring:
#   - pods stuck on the deleted node "bonaventure"
#   - the ClientRepAssist app (namespace callcenter, including its volumes)
#   - the Dynatrace Operator and DynaKube (so the baseline app is not auto-instrumented)
#
# Default is a DRY RUN that only prints the plan. Nothing is deleted without --yes:
#   bash scripts/k3s/run.sh 15-remove-cluster-leftovers.sh
#   bash scripts/k3s/run.sh 15-remove-cluster-leftovers.sh --yes
#
# Dynatrace uninstall order follows Dynatrace's documented procedure: DynaKube first (the
# operator unwinds its agents and finalizers), then the operator, then CRDs, then namespace.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

APPLY=${1:-}
DEAD_NODE=bonaventure
APP_NS=callcenter
DT_NS=dynatrace

echo "================ PLAN ================"
echo "--- pods bound to deleted node $DEAD_NODE (force-removed):"
kubectl get pods -A --field-selector "spec.nodeName=$DEAD_NODE" --no-headers 2>/dev/null || true

echo "--- namespace $APP_NS (deleted with everything in it):"
if kubectl get ns "$APP_NS" >/dev/null 2>&1; then
  kubectl -n "$APP_NS" get deploy,statefulset,svc,pvc --no-headers
else echo "not present"; fi

echo "--- Dynatrace:"
kubectl get dynakube -A --no-headers 2>/dev/null || echo "no DynaKube resources"
HELM_RELEASE=""
if command -v helm >/dev/null && helm -n "$DT_NS" status dynatrace-operator >/dev/null 2>&1; then
  HELM_RELEASE=dynatrace-operator; echo "operator installed by Helm (release dynatrace-operator)"
else
  echo "operator not installed by Helm: cluster-scoped objects removed by label and name"
fi
kubectl get crd -o name | grep 'dynatrace\.com$' || true
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding,csidriver \
  -o name 2>/dev/null | grep -i dynatrace || true

echo "--- host-level OneAgent on soaring (reported only, not removed by this script):"
if [[ -d /opt/dynatrace/oneagent ]]; then echo "PRESENT: /opt/dynatrace/oneagent"; else echo "none"; fi
echo "======================================"

if [[ "$APPLY" != "--yes" ]]; then
  echo "Dry run only. Re-run with --yes to apply."
  exit 0
fi

# 1. ghost pods from the deleted node (their node is gone, so force removal is safe)
kubectl get pods -A --field-selector "spec.nodeName=$DEAD_NODE" --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
  | while read -r ns name; do kubectl -n "$ns" delete pod "$name" --force --grace-period=0; done

# 2. ClientRepAssist
if kubectl get ns "$APP_NS" >/dev/null 2>&1; then
  kubectl delete namespace "$APP_NS" --timeout=300s
fi

# 3. Dynatrace, in the documented order
if kubectl get crd dynakubes.dynatrace.com >/dev/null 2>&1; then
  kubectl -n "$DT_NS" delete dynakube --all
  kubectl -n "$DT_NS" wait --for=delete dynakube --all --timeout=300s || true
fi
if [[ -n "$HELM_RELEASE" ]]; then
  helm uninstall "$HELM_RELEASE" -n "$DT_NS"
else
  kubectl delete mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding,csidriver \
    -l app.kubernetes.io/name=dynatrace-operator --ignore-not-found
fi
# Anything Dynatrace left cluster-wide, matched by name. A webhook left behind without its
# service could block pod creation in every namespace, so none may survive.
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding,csidriver \
  -o name | grep -i dynatrace | xargs -r kubectl delete
kubectl get crd -o name | grep 'dynatrace\.com$' | xargs -r kubectl delete
if kubectl get ns "$DT_NS" >/dev/null 2>&1; then
  kubectl delete namespace "$DT_NS" --timeout=300s
fi

# 4. our pods were created while the Dynatrace webhook was active: recreate them clean
if kubectl get ns online-boutique >/dev/null 2>&1; then
  kubectl -n online-boutique delete pod --all
fi

# 5. result
kubectl get ns
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name
kubectl get pods -A --field-selector "spec.nodeName=$DEAD_NODE" --no-headers 2>/dev/null || true
