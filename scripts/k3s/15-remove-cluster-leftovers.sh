#!/usr/bin/env bash
# Removes what earlier labs left inside the k3s cluster on soaring:
#   - pods stuck "Terminating" for over 10 minutes (left over from the deleted node
#     "bonaventure" and old k3s restarts; their containers no longer exist)
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
APP_NS=callcenter
DT_NS=dynatrace
STUCK_MINUTES=10

# Pods whose deletion was requested more than STUCK_MINUTES ago: "namespace name since"
stuck_pods() {
  local cutoff
  cutoff=$(date -d "-$STUCK_MINUTES min" +%s)
  kubectl get pods -A -o go-template='{{range .items}}{{if .metadata.deletionTimestamp}}{{.metadata.namespace}} {{.metadata.name}} {{.metadata.deletionTimestamp}}{{"\n"}}{{end}}{{end}}' \
    | while read -r ns name since; do
        if (( $(date -d "$since" +%s) < cutoff )); then echo "$ns $name $since"; fi
      done
}

# Delete a namespace; if it does not finish, force-remove its remaining pods and wait again.
delete_ns() {
  local ns=$1
  kubectl get ns "$ns" >/dev/null 2>&1 || return 0
  kubectl delete namespace "$ns" --wait=false
  kubectl wait --for=delete "namespace/$ns" --timeout=120s && return 0
  echo "namespace $ns still terminating; force-removing its remaining pods"
  kubectl -n "$ns" delete pod --all --force --grace-period=0 || true
  kubectl wait --for=delete "namespace/$ns" --timeout=180s && return 0
  echo "namespace $ns is still blocked by:"
  kubectl get ns "$ns" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
  return 1
}

echo "================ PLAN ================"
echo "--- pods stuck Terminating for over $STUCK_MINUTES min (force-removed): namespace, pod, since"
stuck_pods

echo "--- namespace $APP_NS (deleted with everything in it):"
if kubectl get ns "$APP_NS" >/dev/null 2>&1; then
  kubectl get ns "$APP_NS" -o jsonpath='status: {.status.phase}{"\n"}{range .status.conditions[*]}  {.type}: {.message}{"\n"}{end}'
  kubectl -n "$APP_NS" get deploy,statefulset,pod,svc,pvc --no-headers 2>/dev/null || true
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

# 1. pods stuck Terminating (containers already gone, so force removal is safe)
stuck_pods | while read -r ns name _; do kubectl -n "$ns" delete pod "$name" --force --grace-period=0; done

# 2. ClientRepAssist
delete_ns "$APP_NS"

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
delete_ns "$DT_NS"

# 4. our pods were created while the Dynatrace webhook was active: recreate them clean
if kubectl get ns online-boutique >/dev/null 2>&1; then
  kubectl -n online-boutique delete pod --all
fi

# 5. result
kubectl get ns
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name
echo "--- still stuck:"; stuck_pods
