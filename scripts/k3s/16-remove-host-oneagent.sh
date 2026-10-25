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
sudo grep -l 'liboneagentproc' /proc/[0-9]*/maps 2>/dev/null | wc -l || true
echo "==============================================="

if [[ "$APPLY" != "--yes" ]]; then
  echo "Dry run only. Re-run with --yes to uninstall."
  exit 0
fi

sudo "$UNINSTALLER"

# verify
if [[ -d "$AGENT_DIR" ]]; then echo "WARNING: $AGENT_DIR still exists"; else echo "removed: $AGENT_DIR"; fi
systemctl is-active oneagent && echo "WARNING: oneagent service still active" || echo "service: not active"
if grep -qi dynatrace /etc/ld.so.preload 2>/dev/null; then echo "WARNING: /etc/ld.so.preload still references dynatrace"; else echo "ld.so.preload: clean"; fi

# Processes started before the uninstall keep the agent loaded until they restart.
echo "--- processes still holding the agent in memory (restart or reboot clears them):"
sudo grep -l 'liboneagentproc' /proc/[0-9]*/maps 2>/dev/null | wc -l || true
