#!/bin/bash
# deploy-test.sh <image.qcow2> [cd|partition] [user-data file]
#
# Deploys the image to a fresh VM ("deploy") like Ironic would, waits for
# cloudbase-init to finish both passes (the second after the hostname
# reboot), checks its log for errors, takes a screenshot and powers off.
# Results: $VMTEST_DIR/deploy.results, deploy.png, deploy.serial.log.
set -euo pipefail
. "$(dirname "$0")/common.sh"
image=${1:?usage: deploy-test.sh <image.qcow2> [cd|partition] [user-data]}; mode=${2:-cd}; userdata=${3:-}
lock_driver
RESULTS=$VMTEST_DIR/deploy.results; : > "$RESULTS"
"$TOOLS/mkcd.sh" deploy $userdata >/dev/null
"$TOOLS/newdisk.sh" deploy "$image" "$mode" >/dev/null
"$TOOLS/start.sh" deploy >/dev/null
log "deploy: started ($mode config drive)"
rc=0
passes() { LC_ALL=C grep -ac 'Plugins execution done' "$VMTEST_DIR/deploy.serial.log" || true; }
# The first pass ends with the hostname reboot; the second is the full run.
end=$(( $(date +%s) + 3600 ))
until [ "$(passes)" -ge 2 ] || [ "$(date +%s)" -gt "$end" ]; do sleep 15; done
if [ "$(passes)" -ge 2 ]; then
  log "deploy: cloudbase-init finished both passes"
else
  log "deploy: TIMEOUT: cloudbase-init finished $(passes) of 2 passes"; rc=1
fi
LC_ALL=C grep -aoE '(ERROR|CRITICAL) [^\\]{0,150}' "$VMTEST_DIR/deploy.serial.log" | sed 's/^/    /' | tee -a "$RESULTS" || true
LC_ALL=C grep -aoE 'return code: [0-9]+|exit code: [0-9]+' "$VMTEST_DIR/deploy.serial.log" | sed 's/^/    user data \/ local script /' | tee -a "$RESULTS" || true
sleep 60
"$PY" "$TOOLS/qmp.py" deploy shot >/dev/null && log "deploy: screenshot $VMTEST_DIR/deploy.png"
powerdown deploy
log "deploy: done"
exit $rc
