#!/usr/bin/env bash
# Uninstalls the host-level Dynatrace OneAgent from soaring, so neither the VM nor the
# containers k3s runs are auto-instrumented. The Online Boutique baseline must start
# with no instrumentation at all; it is re-instrumented later with OpenTelemetry.
#
# Default is a DRY RUN that only shows the current state. Nothing changes without --yes:
#   bash scripts/k3s/run.sh 16-remove-host-oneagent.sh
#   bash scripts/k3s/run.sh 16-remove-host-oneagent.sh --yes
#
# Uses OneAgent's own documented uninstaller, which removes the systemd unit,
# /opt/dynatrace and the /etc/ld.so.preload entry that injects the agent.
# An operator-deployed agent has no uninstaller; then the script only verifies it is gone
# and removes leftover empty directories.
set -euo pipefail

APPLY=${1:-}
AGENT_DIR=/opt/dynatrace/oneagent
UNINSTALLER=$AGENT_DIR/agent/uninstall.sh
CTL=$AGENT_DIR/agent/tools/oneagentctl

echo "================ CURRENT STATE ================"
if [[ ! -d "$AGENT_DIR" ]]; then
  echo "No OneAgent at $AGENT_DIR: nothing to do."
  exit 0
fi
systemctl is-active oneagent || true
sudo "$CTL" --version || true
sudo "$CTL" --get-host-name --get-host-group --get-server || true
echo "--- /etc/ld.so.preload:"; cat /etc/ld.so.preload 2>/dev/null || echo "(none)"
echo "--- running processes with the agent loaded (count):"
sudo sh -c 'grep -l liboneagentproc /proc/[0-9]*/maps 2>/dev/null | wc -l' || true
echo "==============================================="

if [[ "$APPLY" != "--yes" ]]; then
  echo "Dry run only. Re-run with --yes to uninstall."
  exit 0
fi

if [[ -x "$UNINSTALLER" ]]; then
  # standard (installer-based) OneAgent: use its own uninstaller
  sudo "$UNINSTALLER"
else
  # An agent deployed by the Dynatrace Operator has no uninstaller: the operator's agent pod
  # removes it from the host when the pod stops (done here when 15-remove-cluster-leftovers
  # deleted the dynatrace namespace). Only proceed if its service and injection hook are gone.
  echo "No uninstaller at $UNINSTALLER: operator-deployed agent, removed by the operator on teardown"
  if systemctl cat oneagent >/dev/null 2>&1 || grep -qi dynatrace /etc/ld.so.preload 2>/dev/null; then
    echo "ERROR: oneagent service or ld.so.preload hook still present; not removing anything"
    exit 1
  fi
  # remove only leftover EMPTY directories; any file left in /opt/dynatrace stops this
  sudo find /opt/dynatrace -depth -type d -empty -delete
  if [[ -e /opt/dynatrace ]]; then
    echo "ERROR: /opt/dynatrace still contains files:"; sudo find /opt/dynatrace | head -20
    exit 1
  fi
fi

# verify
if [[ -d "$AGENT_DIR" ]]; then echo "WARNING: $AGENT_DIR still exists"; else echo "removed: $AGENT_DIR"; fi
systemctl is-active oneagent && echo "WARNING: oneagent service still active" || echo "service: not active"
if grep -qi dynatrace /etc/ld.so.preload 2>/dev/null; then echo "WARNING: /etc/ld.so.preload still references dynatrace"; else echo "ld.so.preload: clean"; fi

# Processes started before the uninstall keep the agent loaded until they restart.
echo "--- processes still holding the agent in memory (restart or reboot clears them):"
sudo sh -c 'grep -l liboneagentproc /proc/[0-9]*/maps 2>/dev/null | wc -l' || true
