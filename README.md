# Windows 11 Enterprise whole-disk image for Ironic (UEFI)

Packer + QEMU/KVM build of a sysprepped Windows 11 Enterprise qcow2 for
OpenStack Ironic. The image is UEFI/GPT only (no BIOS support) and includes
cloudbase-init, virtio-win and your vendor drivers.

## Layout

```text
windows-11-ironic.pkr.hcl              Packer template
templates/autounattend.xml.pkrtpl      Build-time answer file (on the build CD)
templates/sysprep-unattend.xml.pkrtpl  Answer file sysprep applies on the deployed node
templates/cloudbase-init*.conf.pkrtpl  cloudbase-init config (service and specialize stage)
templates/post-deploy.ps1.pkrtpl       First-boot hardening, run from SetupComplete.cmd
files/SetupComplete.cmd
scripts/setup-winrm.ps1                First logon: enables WinRM for Packer (on the build CD)
scripts/*.ps1                          Provisioners, plus sysprep.ps1 (the shutdown command)
drivers/vendor-drivers/                Extracted bare-metal drivers (.inf trees)
```

## Build host requirements

Rocky/RHEL 10 package names:

```bash
sudo dnf install qemu-kvm edk2-ovmf xorriso
```

You also need Packer 1.10+ (`packer init` fetches the QEMU plugin), access to
`/dev/kvm`, and outbound internet from the build VM to download virtio-win and
cloudbase-init. Allow about 25 GB of free disk for the working image and the
compressed output.

## Build

```bash
packer init windows-11-ironic.pkr.hcl
packer build \
  -var iso_url=/path/to/windows-11-enterprise.iso \
  -var iso_checksum=sha256:<sha256 of the ISO> \
  -var 'image_name=Windows 11 Enterprise' \
  windows-11-ironic.pkr.hcl
```

* `image_name` must match an image in the ISO's `install.wim`. Evaluation media
  uses `Windows 11 Enterprise Evaluation`. To list the names:
  `wiminfo sources/install.wim` (wimlib), or `dism /Get-WimInfo` on Windows.
* Set the locale variables (`ui_language`, `input_locale`, `system_locale`,
  `user_locale`) to match the ISO language. The default is `en-GB`.
* For volume-licensed media, pass `-var product_key=<GVLK>`. Leave it empty
  for evaluation media.
* To watch the install, run with `-var headless=false`, or connect a VNC
  viewer to the `127.0.0.1` port that Packer prints.

The output is `output-windows-11-ironic/windows-11-ironic.qcow2`.

### What the build does

1. Boots the ISO under OVMF on q35 with a SATA disk and an e1000e NIC. Windows
   has inbox drivers for both, so nothing is injected into WinPE.
2. Windows Setup reads `autounattend.xml` from a generated CD (label
   `PACKERCD`). It skips the Windows 11 TPM/Secure Boot/CPU checks for the
   build VM, partitions the disk as GPT (ESP, MSR, C:), and logs on as
   Administrator.
3. On first logon, `setup-winrm.ps1` runs from the CD and Packer connects over
   WinRM.
4. Provisioners then, in order:
   * Configure Windows: RDP with NLA, high-performance power plan, no
     hibernation, BitLocker auto-encryption blocked.
   * Install virtio-win guest tools.
   * Add the vendor drivers.
   * Reboot.
   * Install cloudbase-init and its config files.
   * Install the sysprep answer file.
   * Install `SetupComplete.cmd`.
   * Run the clean-up script (DISM component clean-up, TRIM).
5. `sysprep.ps1` then:
   * Removes per-user AppX packages, which break Windows 11 sysprep.
   * Clears the build-time autologon and Windows Update policy.
   * Resets cloudbase-init state.
   * Runs `sysprep /generalize /oobe /shutdown` with
     `templates/sysprep-unattend.xml.pkrtpl`.

### On first boot of a deployed node

* In the specialize pass, cloudbase-init reads the Ironic config drive. It sets
  the hostname, creates the `Admin` user (set by the `cloudbase_init_username`
  variable) and extends C: to fill the disk.
* OOBE runs without prompts: locales are preset and the account screens are
  hidden.
* `SetupComplete.cmd` removes the build-only WinRM HTTP listener and its
  firewall rule. It also gives the built-in Administrator a random password and
  disables it.
* The cloudbase-init service then applies the rest:
  * network config, including static `network_data.json`
  * the `Admin` password
  * SSH keys
  * the WinRM HTTPS listener
  * user data

`PersistAllDeviceInstalls` is false, so Windows re-detects hardware on the
node instead of keeping the build VM's devices.

## Upload to Glance

```bash
openstack image create windows-11-ironic \
  --disk-format qcow2 --container-format bare \
  --file output-windows-11-ironic/windows-11-ironic.qcow2 \
  --property os_type=windows \
  --property os_distro=windows \
  --property hw_firmware_type=uefi
```

The image has no `kernel_id`/`ramdisk_id`, so Ironic treats it as a whole-disk
image.

UEFI must also be requested through the flavor and node, because Ironic does
not take the boot mode from the image:

```bash
openstack flavor set <baremetal-flavor> --property capabilities:boot_mode=uefi
openstack baremetal node set <node> --property capabilities='boot_mode:uefi'
```

A password for `Admin` can come from either of these:

* `--property admin_pass=...` in the instance metadata.
* A user-data `#ps1` script.

If neither is set, cloudbase-init generates a random password. Without the
Nova metadata service there is then no way to retrieve it, so set one
explicitly when using config drive only.

## Secure Boot

Secure Boot works on the bare-metal nodes; nothing in the image needs to
change. Windows' boot chain (`bootmgfw.efi` and `\EFI\Boot\bootx64.efi` on the
ESP) is signed by Microsoft and trusted by the default `db` on server
firmware. The build VM does not use Secure Boot, but that does not affect the
image.

To deploy with Secure Boot on:

```bash
openstack baremetal node set <node> --property capabilities='boot_mode:uefi,secure_boot:true'
openstack flavor set <baremetal-flavor> \
  --property capabilities:boot_mode=uefi \
  --property capabilities:secure_boot=true
```

Caveats:

* Use a hardware type that can toggle Secure Boot, such as `redfish`,
  `idrac-redfish`, `ilo` or `irmc`. Ironic enables it at the end of
  deployment, so the IPA ramdisk does not need to be signed for a whole-disk
  deploy. If your nodes already have Secure Boot on during deployment, IPA must
  boot through a signed shim/grub.
* All vendor drivers must be Microsoft-signed (WHQL or attestation). Windows 11
  will not load unsigned kernel drivers with Secure Boot on. The virtio-win
  drivers are Microsoft-signed.
* Keep node firmware `db`/`dbx` current. Microsoft is rotating its 2011 UEFI CA
  to the 2023 CA, so very old firmware may eventually reject newer Windows boot
  managers.
* Device encryption is blocked (`PreventDeviceEncryption`), so a TPM on the
  node does not cause Windows to silently BitLocker the disk. Enable BitLocker
  deliberately if you need it.

## Validating a deployment

* The node boots and the hostname matches the instance name.
* Network works, including static configuration if your network uses it.
* C: fills the disk.
* You can RDP in as `Admin`.
* Logs, under `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\`:
  * `cloudbase-init-unattend.log` (specialize stage)
  * `cloudbase-init.log` (service)
* Logs, under `C:\Windows\Temp\`:
  * `post-deploy.log` (SetupComplete)

cloudbase-init also logs to COM1 at 115200, which shows up on the BMC serial
console.

If the build hangs at sysprep, check
`C:\Windows\System32\Sysprep\Panther\setuperr.log` in the VM.
