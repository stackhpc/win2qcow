# Shared settings for the VM test scripts. Sourced, not run.
#
# State (disks, NVRAM, TPM state, logs, screenshots) goes in $VMTEST_DIR,
# default .cache/vmtest in the repo: git-ignored, and not under /tmp, whose
# cleaner deletes files a few days old.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VMTEST_DIR=${VMTEST_DIR:-$REPO/.cache/vmtest}
TOOLS=$REPO/tests/vm
mkdir -p "$VMTEST_DIR"
PY=${PYTHON:-python3}
[ -x "$VMTEST_DIR/venv/bin/python" ] && PY=$VMTEST_DIR/venv/bin/python
QEMU=${QEMU:-/usr/libexec/qemu-kvm}
OVMF_DIR=${OVMF_DIR:-/usr/share/edk2/ovmf}

log() { echo "$(date +%T) $*" | tee -a "${RESULTS:-/dev/null}"; }

# wait_serial <name> <extended regex> <timeout minutes>: wait for a line in
# the VM's serial log (cloudbase-init logs there, including script output).
wait_serial() {
  local end=$(( $(date +%s) + $3 * 60 ))
  until LC_ALL=C grep -aqE "$2" "$VMTEST_DIR/$1.serial.log" 2>/dev/null; do
    [ "$(date +%s)" -gt "$end" ] && return 1
    sleep 15
  done
}

# running <name>: QEMU deletes its pid file when it exits.
running() { [ -f "$VMTEST_DIR/$1.pid" ] && kill -0 "$(cat "$VMTEST_DIR/$1.pid")" 2>/dev/null; }

# powerdown <name>: ACPI power button, then wait up to 10 minutes.
powerdown() {
  "$PY" "$TOOLS/qmp.py" "$1" powerdown >/dev/null 2>&1
  for _ in $(seq 120); do running "$1" || return 0; sleep 5; done
  log "$1: did not power off, forcing"
  "$PY" "$TOOLS/qmp.py" "$1" quit >/dev/null 2>&1; sleep 3
}

# stop_tpm <name>
stop_tpm() {
  [ -f "$VMTEST_DIR/$1.swtpm.pid" ] && kill "$(cat "$VMTEST_DIR/$1.swtpm.pid")" 2>/dev/null
  return 0
}

# Only one test driver at a time: two drivers driving the same VMs scramble
# each other's results.
lock_driver() {
  exec 9>"$VMTEST_DIR/driver.lock"
  flock -n 9 || { echo "another test driver is running (lock: $VMTEST_DIR/driver.lock)" >&2; exit 1; }
}
