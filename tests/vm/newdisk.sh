#!/bin/bash
# newdisk.sh <name> <image.qcow2> [cd|partition]
#
# A fresh 60G overlay on the image ($VMTEST_DIR/<name>.qcow2) with fresh UEFI
# variables and TPM state, as for a newly deployed node. Run mkcd.sh first.
# With "partition", the config drive is written to a partition at the end of
# the disk, the way Ironic does it (needs sudo for qemu-nbd); with "cd", the
# default, start.sh attaches it as a CD-ROM instead.
set -euo pipefail
. "$(dirname "$0")/common.sh"
name=${1:?usage: newdisk.sh <name> <image.qcow2> [cd|partition]}; image=${2:?image}; mode=${3:-cd}
running "$name" && { echo "$name is running" >&2; exit 1; }
stop_tpm "$name"
for f in qcow2 vars serial.log swtpm.log cdmode png; do rm -f "${VMTEST_DIR:?}/${name:?}.$f"; done
rm -rf "${VMTEST_DIR:?}/${name:?}.tpm"
qemu-img create -q -f qcow2 -b "$(readlink -f "$image")" -F qcow2 "$VMTEST_DIR/$name.qcow2" 60G
echo "$mode" > "$VMTEST_DIR/$name.cdmode"
if [ "$mode" = partition ]; then
  dev=${NBD_DEV:-/dev/nbd0}
  sudo modprobe nbd max_part=16
  sudo qemu-nbd -c "$dev" "$VMTEST_DIR/$name.qcow2"
  trap 'sudo qemu-nbd -d "$dev" >/dev/null' EXIT
  sleep 2
  sudo sgdisk -e "$dev" >/dev/null            # move the backup GPT to the new end
  sudo sgdisk -n 0:-64M:0 "$dev" >/dev/null   # 64M partition at the end
  sudo partprobe "$dev"; sleep 1
  part=$(lsblk -lnpo NAME "$dev" | tail -1)
  sudo dd if="$VMTEST_DIR/$name.iso" of="$part" bs=1M conv=fsync status=none
fi
echo "$VMTEST_DIR/$name.qcow2"
