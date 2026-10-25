#!/usr/bin/env bash
# Runs one phase script with a full command trace, saved to logs/k3s/<script>.log
#
#   bash scripts/k3s/run.sh 00-preflight.sh
#   bash scripts/k3s/run.sh 10-remove-clientrepassist.sh --yes
#
# Every command the script executes is printed with a timestamp ("+ 14:02:11 cmd ...")
# so the log is a complete, reviewable record of what was run on soaring.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

script=${1:?usage: run.sh <script> [args...]}; shift
mkdir -p logs/k3s
log="logs/k3s/${script%.sh}.log"

echo "### $(date -Is) running scripts/k3s/$script $*" | tee "$log"
PS4='+ $(date +%T) ' bash -x "scripts/k3s/$script" "$@" 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}
echo "### $(date -Is) exit code $rc" | tee -a "$log"
exit "$rc"
