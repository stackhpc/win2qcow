---
name: vm-test
description: Test a built Windows image by deploying it to a local QEMU VM the way Ironic would (config drive, fresh UEFI NVRAM, optional TPM 2.0 and Secure Boot), then checking cloudbase-init, user data or BitLocker results from the serial console, screenshots and the disk. Use after building an image, before calling a change to the build, templates, cloudbase-init config or first-boot scripts done.
---

# Testing images in local VMs

The scripts are in `tests/vm/` (see the header of each). State goes in
`.cache/vmtest/` (git-ignored). Never keep test state or tools under `/tmp`:
its cleaner deleted a whole earlier harness after about ten days.

| Script | Does |
|---|---|
| `mkcd.sh <name> [user-data]` | Config drive ISO: fresh uuid, hostname, Admin password (`.cache/vmtest/admin_pass`), DHCP network |
| `newdisk.sh <name> <image> [cd\|partition]` | Fresh 60G overlay, NVRAM and TPM state. `partition` writes the config drive to a partition at the end of the disk, as Ironic does (needs sudo) |
| `start.sh <name> [--tpm] [--no-secure-boot] [--no-cd]` | Boots it: Secure Boot OVMF, SATA, e1000e, serial log, VNC and QMP on localhost, optional swtpm TPM 2.0 |
| `qmp.py <name> powerdown\|quit\|status\|shot [png]` | Control and screenshots, through QMP |
| `deploy-test.sh <image> [cd\|partition] [user-data]` | Deploy, wait for both cloudbase-init passes, report errors, screenshot |
| `bitlocker-test.sh <image>` | For `bitlocker=true` images: enable and TPM unlock, cold boot, boot without the TPM (recovery screen), deploy without a TPM |

Screenshots need Pillow: `python3 -m venv .cache/vmtest/venv &&
.cache/vmtest/venv/bin/pip install pillow` (the scripts use that venv when
it exists). Read the PNGs to check what is on screen: a log line saying
Windows "did not start" proves nothing on its own.

## Running tests

- A deploy takes about 8 minutes to the second cloudbase-init pass. The
  BitLocker suite takes about 45 minutes, and its encrypted overlay grows to
  the size of the used data (about 20 GB). Check `df -h /` first.
- Run long tests detached, so a dropped SSH session doesn't kill them:
  `setsid nohup tests/vm/bitlocker-test.sh IMAGE > .cache/vmtest/run.out 2>&1 < /dev/null &`.
  Then wait for the results file with a background `until` loop rather than
  polling.
- Test drivers take a lock (`.cache/vmtest/driver.lock`). Two drivers on the
  same VMs once scrambled a whole run. If a session drops, check for an old
  driver before starting another: `ps -eo pid=,args= | awk '$2 ~ /tests\/vm\//'`.
- Clean up when done: power off the VMs, remove the overlays
  (`.cache/vmtest/<name>.qcow2`), and stop leftover swtpm processes
  (`.cache/vmtest/<name>.swtpm.pid`).

## Reading results

- The serial log (`.cache/vmtest/<name>.serial.log`) has cloudbase-init's
  log, including the stdout and stderr of user data and LocalScripts, as
  Python byte strings with literal `\r\n`. Match with
  `LC_ALL=C grep -aoE '...[^\\]{0,160}'`. The log is truncated each time
  QEMU starts, but not when Windows reboots itself.
- "Plugins execution done" marks the end of a cloudbase-init pass: one before
  the hostname reboot, one after. Script results show as `ended with exit
  code: N` (LocalScripts) or `return code: N` (user data).
- Checking inside Windows: WinRM as `Admin` gets a filtered token (UAC remote
  restrictions are on by default), so prefer the serial log, screenshots and
  offline checks. Offline: `sudo qemu-nbd -r -c /dev/nbdN disk.qcow2`, mount
  partition 4 read-only with `ntfs-3g -o ro`, copy files or registry hives
  out (read hives with the `regipy` Python package). Not possible once
  BitLocker has encrypted the disk.
- A BitLocker recovery screen left alone powers the VM off after about a
  minute, so take that screenshot within 40 seconds of starting.

## Pitfalls (each cost real time)

- Matching processes with `pgrep -f`, `pkill -f` or `/proc/*/cmdline` also
  matches the shell running the command, which then kills itself. Match on
  the process's script argument: `ps -eo pid=,args= | awk '$2 ~ /pattern/'`.
- UNIX socket paths are limited to 108 bytes: QMP uses localhost TCP, and the
  swtpm socket lives in `/tmp/vmtest-swtpm-<name>.sock`.
- `swtpm_setup --create-ek-cert` fails as a normal user with the system CA in
  `/var/lib/swtpm-localca`; `start.sh` makes a local one.
- Secure Boot OVMF (`OVMF_CODE.secboot.fd`) needs `-machine ...,smm=on` and
  `-global driver=cfi.pflash01,property=secure,value=on`.
- QEMU deletes its pid file on exit: a missing pid file means it stopped.
- Don't edit a shell script while it is running (bash reads it as it goes),
  or a `.ps1`/template while Packer may still read it.
- `rm -rf "$DIR/$name..."` is blocked by a safety check unless the variables
  are guarded: write `"${DIR:?}/${name:?}..."`.
