#!/bin/bash
# bitlocker-test.sh <image.qcow2 built with bitlocker=true>
#
# 1. "bl": fresh deploy with a TPM 2.0 and Secure Boot. Expect ENABLED, a
#    reboot, then OK; and no recovery password on the serial console.
# 2. Cold boot of the same disk with the same TPM: expect Windows to start.
# 3. The same disk without its TPM: expect the BitLocker recovery screen
#    (Windows powers the VM off a minute or two later).
# 4. "bl-notpm": fresh deploy without a TPM. Expect FAILED, exit code 1002
#    (run again next boot), and a usable node.
# Results: $VMTEST_DIR/bitlocker.results and screenshots bl-*.png.
set -euo pipefail
. "$(dirname "$0")/common.sh"
image=${1:?usage: bitlocker-test.sh <image.qcow2>}
lock_driver
RESULTS=$VMTEST_DIR/bitlocker.results; : > "$RESULTS"
serial=$VMTEST_DIR/bl.serial.log
status_lines() {  # status_lines <serial log>: the script's report lines
  LC_ALL=C grep -aoE '(BitLocker setup|TPM present|TPM spec|Secure Boot|Volume status|Key protectors|TPM PCR|Booted)[^\\]{0,160}' "$1" |
    tail -8 | sed 's/^/    /' | tee -a "$RESULTS" || true
}
shot() { "$PY" "$TOOLS/qmp.py" "$1" shot "$VMTEST_DIR/$2.png" >/dev/null 2>&1 && log "screenshot $VMTEST_DIR/$2.png" || log "$1: no screenshot (VM not running)"; }

# 1
"$TOOLS/mkcd.sh" bl >/dev/null; "$TOOLS/newdisk.sh" bl "$image" >/dev/null; "$TOOLS/start.sh" bl --tpm >/dev/null
log "1: deployed with TPM 2.0 and Secure Boot"
# The serial log is truncated at each start, but the VM reboots itself here,
# so it holds the ENABLED run, the reboot and the OK run.
if wait_serial bl 'BitLocker setup: (OK|FAILED)' 90; then
  log "1: $(LC_ALL=C grep -ac 'BitLocker setup: ENABLED' "$serial") ENABLED report(s), then:"
  status_lines "$serial"
else
  log "1: TIMEOUT waiting for a BitLocker result"
fi
if LC_ALL=C grep -aqE 'ACTIONS REQUIRED|[0-9]{6}(-[0-9]{6}){7}' "$serial"; then
  log "1: FAIL: a recovery password (or the cmdlet warning that prints it) is on the serial console"
else
  log "1: no recovery password on the serial console"
fi
sleep 60; shot bl bl-1-deployed; powerdown bl

# 2
"$TOOLS/start.sh" bl --tpm --no-cd >/dev/null; log "2: cold boot with the same TPM"
if wait_serial bl 'cloudbaseinit' 15; then log "2: Windows started (cloudbase-init is running)"; else log "2: FAIL: Windows did not start"; fi
sleep 90; shot bl bl-2-cold-boot; powerdown bl

# 3
"$TOOLS/start.sh" bl --no-cd >/dev/null; log "3: same disk, no TPM"
sleep 40; shot bl bl-3-no-tpm
if LC_ALL=C grep -aq 'cloudbaseinit' "$serial"; then log "3: FAIL: Windows started without the TPM"; else log "3: Windows did not start (check the screenshot shows BitLocker recovery)"; fi
"$PY" "$TOOLS/qmp.py" bl quit >/dev/null 2>&1 || true; sleep 3; stop_tpm bl

# 4
"$TOOLS/mkcd.sh" bl-notpm >/dev/null; "$TOOLS/newdisk.sh" bl-notpm "$image" >/dev/null; "$TOOLS/start.sh" bl-notpm >/dev/null
log "4: deployed without a TPM"
if wait_serial bl-notpm 'BitLocker setup: ' 45; then
  status_lines "$VMTEST_DIR/bl-notpm.serial.log"
  LC_ALL=C grep -aoE 'enable-bitlocker.ps1" ended with exit code: [0-9]+' "$VMTEST_DIR/bl-notpm.serial.log" | tail -1 | sed 's/^/    /' | tee -a "$RESULTS" || true
else
  log "4: TIMEOUT waiting for a BitLocker result"
fi
sleep 60; shot bl-notpm bl-4-no-tpm-deployed; powerdown bl-notpm
log "done"
