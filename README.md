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
files/SetupComplete.cmd                Enables the cloudbase-init service after OOBE
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
cloudbase-init. Both downloads are pinned versions verified by SHA-256
(`virtio_win_guest_tools_url`/`_sha256`, `cloudbase_init_url`/`_sha256`).
Allow about 50 GB of free disk: the working image and the
compressed copy exist side by side while Packer converts it.

## Build

```bash
# Administrator password for the build VM only; randomised before sysprep.
export PKR_VAR_build_password="Pk-$(openssl rand -base64 18)"

packer init windows-11-ironic.pkr.hcl
packer build \
  -var iso_url=/path/to/windows-11-enterprise.iso \
  -var iso_checksum=sha256:<sha256 of the ISO> \
  -var 'image_name=Windows 11 Enterprise' \
  windows-11-ironic.pkr.hcl
```

* `image_name` must match an image name in the ISO's `install.wim`, and the
  locale variables (`ui_language`, `input_locale`, `system_locale`,
  `user_locale`, default `en-GB`) must match a language on the ISO. See
  [Checking the ISO](#checking-the-iso).
* `product_key` defaults to the public Windows 11 Enterprise KMS client key
  (GVLK), or to no key when `image_name` contains `Evaluation`. Without a key,
  Setup stops at the product key page on non-evaluation media.
* Vendor drivers go in `drivers/vendor-drivers/`, or point `vendor_drivers_dir`
  at another directory. See [Adding vendor drivers](#adding-vendor-drivers).
* To watch the install, run with `-var headless=false`, or connect a VNC
  viewer to the `127.0.0.1` port that Packer prints.

The output is `output-windows-11-ironic/windows-11-ironic.qcow2`.

During the build the VM's WinRM endpoint (HTTP, Basic auth, Administrator) is
forwarded to a port on `127.0.0.1` only. Anyone with a shell on the build host
can reach it while the build runs.

### Checking the ISO

Windows ISOs keep their files in a UDF filesystem, and the edition list lives
in the XML metadata of `sources/install.wim`. `wiminfo` (from wimlib) prints
it. Rocky/RHEL 10 don't package wimlib, even in EPEL (Fedora has
`wimlib-utils`, Debian/Ubuntu `wimtools`), so build it once:

```bash
curl -LO https://wimlib.net/downloads/wimlib-1.14.5.tar.gz
tar xzf wimlib-1.14.5.tar.gz && cd wimlib-1.14.5
./configure --prefix="$HOME/.local" --without-fuse --without-ntfs-3g
make -j"$(nproc)" && make install       # installs ~/.local/bin/wiminfo
cd ..
```

Then mount the ISO read-only and read the WIM in place (nothing is copied):

```bash
ISO=/path/to/windows-11-enterprise.iso
sudo mkdir -p /mnt/win-iso
sudo mount -o loop,ro "$ISO" /mnt/win-iso
wiminfo /mnt/win-iso/sources/install.wim | grep -E '^(Index|Name|Edition ID|Languages|Default Language|Build):'
sudo umount /mnt/win-iso
```

For the Windows 11 Enterprise evaluation ISO (25H2, en-GB) this prints:

```text
Index:                  1
Name:                   Windows 11 Enterprise Evaluation
Edition ID:             EnterpriseEval
Languages:              en-GB
Default Language:       en-GB
Build:                  26200
```

* Pass `Name` as `image_name`, e.g.
  `-var 'image_name=Windows 11 Enterprise Evaluation'`. Business (volume)
  media contains several images, such as `Windows 11 Enterprise`,
  `Windows 11 Education` and `Windows 11 Pro`; pick the Enterprise one.
* Set the locale variables to a value from `Languages`.
* Some media ship `sources/install.esd` instead; `wiminfo` reads that too.
* Without root, `7z x "$ISO" sources/install.wim` (the `7zip` package from
  EPEL) extracts the WIM instead of mounting, at the cost of a ~6 GB copy.

### Adding vendor drivers

Every `.inf` found under `vendor_drivers_dir` is staged into the image's driver
store, so Windows finds drivers for the node's hardware on first boot. Only
add what a headless Ironic node needs: network, storage and chipset drivers.
Leave out GPU, audio and other desktop drivers; they are large and unused.

Drivers must be 64-bit, for Windows 11, and Microsoft-signed (WHQL or
attestation signed), or Windows 11 won't load them, Secure Boot or not.
Keep path components under 64 characters: the build CD uses Joliet names.

#### Example: Dell Precision 7960 Rack

The Precision 7960 Rack is a 2U workstation with an iDRAC, so Ironic can drive
it with the `idrac` or `redfish` hardware type, and Dell supports Windows 11
on it. Dell publishes a Windows 11 driver pack per model, listed in its driver
pack catalog with download paths and SHA-256 hashes.

1. Find the current pack in Dell's catalog (`cabextract` and `7zip` are in
   EPEL):

   ```bash
   sudo dnf install -y 7zip
   curl -LO https://downloads.dell.com/catalog/DriverPackCatalog.cab
   7z x -y DriverPackCatalog.cab          # -> DriverPackCatalog.xml
   grep -o 'path="[^"]*Precision-7960-Rack[^"]*Win11[^"]*"' DriverPackCatalog.xml
   ```

   At the time of writing that is release `DVXGJ`, version A09:

   ```text
   path="FOLDER14214605M/1/Precision-7960-Rack-DVXGJ_Win11_1.0_A09.exe"
   ```

   The SHA-256 is in the `<Hash algorithm="SHA256">` element of the same
   `<DriverPackage>` entry.

2. Download and verify it:

   ```bash
   curl -LO https://downloads.dell.com/FOLDER14214605M/1/Precision-7960-Rack-DVXGJ_Win11_1.0_A09.exe
   echo "637b463754deaa8b8f456ffb0d3a4ac5eac2e90d96f3d80403881a4a04c39456  Precision-7960-Rack-DVXGJ_Win11_1.0_A09.exe" | sha256sum -c
   ```

3. Extract only the folders a server needs. The pack is a self-extracting
   `.exe`, but 7-Zip opens it directly on Linux. Of its 3.4 GB, 3.2 GB is GPU
   drivers; the three folders below come to about 12 MB:

   ```bash
   7z x -y Precision-7960-Rack-DVXGJ_Win11_1.0_A09.exe -o/tmp/dell-7960 \
     'Precision-7960-Rack/Win11/x64/network/*' \
     'Precision-7960-Rack/Win11/x64/storage/*' \
     'Precision-7960-Rack/Win11/x64/chipset/*'
   rm -rf drivers/vendor-drivers/precision-7960-rack
   cp -r /tmp/dell-7960/Precision-7960-Rack/Win11/x64 drivers/vendor-drivers/precision-7960-rack
   ```

   (On Windows, `Precision-7960-Rack-DVXGJ_Win11_1.0_A09.exe /s /e=C:\dell-7960`
   extracts the whole pack.)

   What's in them for this model:

   | Folder | Drivers | Hardware |
   |---|---|---|
   | `network/` | `e1r.inf`, `ixs.inf`, `i40ea.inf`, `icea.inf` | Intel I210 1 GbE, X710, XL710 and E810 NICs |
   | `storage/` | `iaVROC.inf`, `iaStorE.inf`, ... | Intel VROC (NVMe RAID) and RST SATA |
   | `chipset/` | `SapphireRapidsSystem.inf`, `EmmitsburgSystem.inf`, ... | Intel Xeon W / W790 chipset devices |

4. Build as normal. The build log lists each INF that was added, then the
   driver store contents, for example:

   ```text
   Adding E:\vendor-drivers\precision-7960-rack\network\732VN_A00-00\PROCGB\icea.inf
   ```

   Packer puts the whole `vendor-drivers` directory on the CD, so one image
   can carry drivers for several models side by side.

Notes:

* NICs or HBAs added to the node (e.g. Broadcom or NVIDIA/Mellanox cards)
  aren't in the model's driver pack. Download those vendors' Windows 11
  drivers, extract the `.inf`/`.sys`/`.cat` files and add a directory for
  each.
* If the node boots from an Intel VROC RAID volume, test a deploy: VROC is
  boot-critical, and drivers staged into a running Windows may not be enough
  to boot from it (see [Limitations](#limitations)). NVMe or SATA drives not
  in a RAID volume use Windows' inbox drivers and are unaffected.

### What the build does

1. Boots the ISO under OVMF on q35 with a SATA disk and an e1000e NIC. Windows
   has inbox drivers for both, so nothing is injected into WinPE.
2. Windows Setup reads `autounattend.xml` from a generated CD (label
   `PACKERCD`). It skips the Windows 11 TPM/Secure Boot/CPU checks for the
   build VM and partitions the disk as GPT: ESP, MSR, a 1 GB WinRE partition,
   then C: taking the rest. C: is last so it can be extended on deploy;
   without the WinRE partition, Setup shrinks C: to create one after it.
   Setup then logs on as Administrator.
3. On first logon, `setup-winrm.ps1` runs from the CD and Packer connects over
   WinRM.
4. Provisioners then, in order:
   * Configure Windows: RDP with NLA, high-performance power plan, no
     hibernation, BitLocker auto-encryption blocked, Smart App Control off.
   * Install virtio-win guest tools.
   * Stage the vendor drivers in the driver store.
   * Reboot.
   * Install cloudbase-init and its config files. The service is left on
     Manual so it can't run during the build.
   * Install the sysprep answer file.
   * Install `SetupComplete.cmd`.
   * Run the clean-up script (DISM component clean-up, TRIM).
5. Packer's shutdown command runs `sysprep.ps1`. It starts a scheduled task
   (as SYSTEM) and returns, because Windows kills processes started from a
   WinRM shell when Packer closes it. The task:
   * Removes AppX packages installed for a user but not provisioned, which
     break Windows 11 sysprep.
   * Removes the build-only Windows Update and Store auto-update policies and
     the autologon. Consumer features stay disabled.
   * Removes the WinRM HTTP listener, Basic auth, unencrypted access and the
     WinRM firewall rules.
   * Gives the built-in Administrator a random password and disables it
     (unless `cloudbase_init_username` is `Administrator`).
   * Deletes Setup's cached copies of the build answer file, which hold the
     build password in plain text.
   * Resets cloudbase-init state.
   * Runs `sysprep /generalize /oobe /shutdown` with
     `templates/sysprep-unattend.xml.pkrtpl`, which powers the VM off.

### On first boot of a deployed node

* In the specialize pass, the scheduled task left from the build is deleted,
  then cloudbase-init reads the Ironic config drive. It creates the `Admin`
  user (set by the `cloudbase_init_username` variable) and extends C: to fill
  the disk.
* OOBE runs without prompts: locales are preset, the account screens are
  hidden, and `SkipMachineOOBE`/`SkipUserOOBE` stop Windows 11 running its
  user OOBE in a temporary `defaultuser0` session. Without them that session's
  Explorer crashes and Windows restarts into "Why did my PC restart?".
* `SetupComplete.cmd` switches the cloudbase-init service to Automatic and
  starts it. It then applies the rest:
  * the hostname (Windows 11 OOBE would overwrite a name set earlier)
  * network config, including static `network_data.json`
  * the `Admin` password
  * the WinRM HTTPS listener
  * user data and local scripts
* cloudbase-init then reboots once so the hostname takes effect. The node is
  ready at the logon screen after that reboot.

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

The nodes must boot in UEFI mode. Ironic doesn't take the boot mode from the
image. UEFI has been Ironic's default since Yoga, so this is only needed if
your deployment overrides that default:

```bash
openstack flavor set <baremetal-flavor> --property capabilities:boot_mode=uefi
openstack baremetal node set <node> --property capabilities='boot_mode:uefi'
```

`node set --property capabilities=...` replaces the node's whole capabilities
string, so include any capabilities the node already has.

**A config drive is required.** cloudbase-init creates the only enabled admin
account (`Admin`) during the specialize pass. If it finds no metadata, the
node finishes OOBE with no usable account. Boot instances with
`--config-drive true`, or set `force_config_drive = true` in Nova.

A password for `Admin` can come from either of these, and is not forced to
change at first logon, so RDP with NLA works straight away:

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
# Replaces the node's capabilities string; keep any existing entries.
openstack baremetal node set <node> --property capabilities='boot_mode:uefi,secure_boot:true'
openstack flavor set <baremetal-flavor> \
  --property capabilities:boot_mode=uefi \
  --property capabilities:secure_boot=true
```

Caveats:

* Use a hardware type that can toggle Secure Boot, such as `redfish`, `idrac`,
  `ilo` or `irmc`. Ironic enables it at the end of
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

cloudbase-init also logs to COM1 at 115200, which shows up on the BMC serial
console.

## Limitations

* **Boot-critical storage drivers.** Vendor drivers are staged in the driver
  store while Windows is running. That is enough for NICs and for storage that
  isn't the boot disk. If a node boots from a controller with no inbox Windows
  driver (some RAID/HBA cards), test a deploy. It may need the driver injected
  offline with `dism /Add-Driver` to avoid `INACCESSIBLE_BOOT_DEVICE`.
* **Non-English ISOs.** `groups=Administrators` in the cloudbase-init configs
  is the English group name. Change it to the localised name (for example
  `Administratoren`) for other languages.
* **Build password remnants.** Windows Setup and sysprep make working copies
  of the build answer file and free them during sysprep, after the last point
  the build can run anything. A raw scan of the image's disk blocks therefore
  finds a few deleted copies containing `build_password`. They grant nothing:
  that password belongs only to the built-in Administrator, which is given a
  random password and disabled before sysprep. Use a fresh random
  `build_password` per build (as above) and never reuse a real credential.
* **SSH keys** are not applied: OpenSSH Server isn't installed.
* **Build-time update check.** Windows 11 OOBE in the build VM shows "Checking
  for updates" and may download a zero-day update from Microsoft. It needs
  internet access, and it is the most variable part of the build time
  (builds took 47–49 minutes on a nested-KVM host).
* **Profile error in specialize.** cloudbase-init creates `Admin` in the
  specialize pass, before Windows can load user profiles, so
  `cloudbase-init-unattend.log` shows a `LoadUserProfile` "device is not
  ready" error. It's harmless: the user and password are set, and the
  profile is created at first logon.
* **Smart App Control** is turned off in the image. It starts in evaluation
  mode and can switch itself on and block unsigned code, such as user-data
  scripts. It can only be re-enabled by reinstalling Windows.

If the build hangs at sysprep, check
`C:\Windows\System32\Sysprep\Panther\setuperr.log` in the VM.
