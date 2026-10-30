#!/bin/bash
# start.sh <name> [--tpm] [--no-secure-boot] [--no-cd]
#
# Boots $VMTEST_DIR/<name>.qcow2 (from newdisk.sh) like a bare-metal node:
# q35, UEFI with Secure Boot (Microsoft keys enrolled) unless
# --no-secure-boot, SATA disk, e1000e NIC on user networking, serial console
# to $VMTEST_DIR/<name>.serial.log (truncated at each start), VNC and QMP on
# localhost. The config drive is attached as a CD unless newdisk.sh wrote it
# to a partition, or --no-cd.
#
# --tpm adds a TPM 2.0 (swtpm) whose state persists in $VMTEST_DIR/<name>.tpm/
# across starts, like a real one. Ports are fixed per name (see qmp.py).
set -euo pipefail
. "$(dirname "$0")/common.sh"
name=${1:?usage: start.sh <name> [--tpm] [--no-secure-boot] [--no-cd]}; shift
tpm=0; sb=1; cd=1
for a in "$@"; do
  case $a in
    --tpm) tpm=1 ;;
    --no-secure-boot) sb=0 ;;
    --no-cd) cd=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
running "$name" && { echo "$name is already running" >&2; exit 1; }
n=$("$PY" "$TOOLS/qmp.py" "$name" index)
args=(-name "$name" -cpu host -smp 4 -m 8192)
if [ $sb = 1 ]; then
  [ -f "$VMTEST_DIR/$name.vars" ] || cp "$OVMF_DIR/OVMF_VARS.secboot.fd" "$VMTEST_DIR/$name.vars"
  # Secure Boot firmware needs SMM and a secure flash.
  args+=(-machine q35,accel=kvm,smm=on -global driver=cfi.pflash01,property=secure,value=on
         -drive "file=$OVMF_DIR/OVMF_CODE.secboot.fd,if=pflash,unit=0,format=raw,readonly=on")
else
  [ -f "$VMTEST_DIR/$name.vars" ] || cp "$OVMF_DIR/OVMF_VARS.fd" "$VMTEST_DIR/$name.vars"
  args+=(-machine q35,accel=kvm -drive "file=$OVMF_DIR/OVMF_CODE.fd,if=pflash,unit=0,format=raw,readonly=on")
fi
args+=(-drive "file=$VMTEST_DIR/$name.vars,if=pflash,unit=1,format=raw"
       -drive "file=$VMTEST_DIR/$name.qcow2,if=ide,format=qcow2,cache=writeback")
mode=$(cat "$VMTEST_DIR/$name.cdmode" 2>/dev/null || echo cd)
if [ $cd = 1 ] && [ "$mode" = cd ] && [ -f "$VMTEST_DIR/$name.iso" ]; then
  args+=(-drive "file=$VMTEST_DIR/$name.iso,media=cdrom")
fi
if [ $tpm = 1 ]; then
  st=$VMTEST_DIR/$name.tpm
  if [ ! -f "$st/tpm2-00.permall" ]; then
    # A local CA for the EK and platform certificates: the system one in
    # /var/lib/swtpm-localca is only writable by the tss user.
    ca=$VMTEST_DIR/swtpm-localca
    mkdir -p "$ca" "$st"
    printf 'statedir = %s\nsigningkey = %s/signkey.pem\nissuercert = %s/issuercert.pem\ncertserial = %s/certserial\n' \
      "$ca" "$ca" "$ca" "$ca" > "$ca/localca.conf"
    printf -- '--platform-manufacturer QEMU\n--platform-version 2.1\n--platform-model QEMU\n' > "$ca/localca.options"
    printf 'create_certs_tool = /usr/bin/swtpm_localca\ncreate_certs_tool_config = %s/localca.conf\ncreate_certs_tool_options = %s/localca.options\n' \
      "$ca" "$ca" > "$ca/swtpm_setup.conf"
    swtpm_setup --config "$ca/swtpm_setup.conf" --tpm2 --tpmstate "$st" \
      --create-ek-cert --create-platform-cert --lock-nvram --overwrite >/dev/null
  fi
  stop_tpm "$name"; sleep 1
  # UNIX socket paths are limited to 108 bytes, so not in $VMTEST_DIR.
  sock=/tmp/vmtest-swtpm-$name.sock
  rm -f "${sock:?}"
  swtpm socket --tpm2 --tpmstate "dir=$st" --ctrl "type=unixio,path=$sock" --daemon \
    --pid "file=$VMTEST_DIR/$name.swtpm.pid" --log "file=$VMTEST_DIR/$name.swtpm.log,level=1"
  sleep 1
  args+=(-chardev "socket,id=chrtpm,path=$sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
fi
args+=(-netdev user,id=n0 -device e1000e,romfile=,netdev=n0,mac=52:54:00:12:34:57
       -serial "file:$VMTEST_DIR/$name.serial.log" -vnc "127.0.0.1:$((80 + n))"
       -qmp "tcp:127.0.0.1:$((4450 + n)),server,nowait" -daemonize -pidfile "$VMTEST_DIR/$name.pid")
"$QEMU" "${args[@]}"
echo "$name started: VNC 127.0.0.1:$((5980 + n)), QMP 127.0.0.1:$((4450 + n)), serial $VMTEST_DIR/$name.serial.log"
