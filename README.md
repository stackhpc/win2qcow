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
scripts/setup-winrm.ps1                Audit-mode sign-in: enables WinRM for Packer (on the build CD)
scripts/*.ps1                          Provisioners, plus sysprep.ps1 (the shutdown command)
variants/*.toml                        Known hardware variants: driver packages and devices
scripts/drivers.py                     Fetches, unpacks and checks a variant's drivers
scripts/build-variant.sh               Fetch a variant's drivers, then packer build
scripts/collect-diagnostics.ps1        Run on a deployed node to collect first-boot logs
drivers/vendor-drivers/                Hand-extracted drivers, for builds without a variant
design-notes.md                        Design decisions and how each script works
TODO.md                                Known follow-up work
LICENSE                                Apache License 2.0
```

## Build host requirements

Rocky/RHEL 10 package names:

```bash
sudo dnf install qemu-kvm edk2-ovmf xorriso
# For hardware variants (scripts/drivers.py): 7-Zip from EPEL, and pymsi
sudo dnf install 7zip
python3 -m venv .venv && .venv/bin/pip install -r requirements-drivers.txt
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
* `product_key` defaults to Microsoft's public KMS client key (GVLK) for the
  edition in `image_name` (Enterprise, Education, Pro and their N variants),
  or to no key when `image_name` contains `Evaluation`. For any other edition,
  set `product_key`: without a valid key, Setup stops at the product key page
  and the build waits until it times out.
* `remote_local_admin` (default `false`) controls whether the local admin
  account can manage a node remotely with full rights (WinRM, Ansible, admin
  shares). By default UAC remote restrictions stay on, as cloudbase-init
  intends: RDP works, but remote admin needs a domain account. Set it to
  `true` for nodes you manage over WinRM as `Admin`.
* To include drivers for specific hardware, build a variant with
  `scripts/build-variant.sh` instead; see [Hardware variants](#hardware-variants).
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

### Hardware variants

A variant is a file in `variants/` describing one hardware model: the vendor
driver packages to include, pinned by URL and SHA-256, and the devices the
model can contain. Known variants:

| Variant | Hardware |
|---|---|
| `dell-poweredge-r740xd` | Dell PowerEdge R740xd (SKU 0737), every NIC, storage and FC option Dell lists for it, including Mellanox ConnectX-3 to ConnectX-7 |
| `dell-precision-7960-rack` | Dell Precision 7960 Rack, from Dell's Windows 11 driver pack |
| `hpe-proliant-dl360-gen10` | HPE ProLiant DL360 Gen10, every NIC, Smart Array, FC and iLO option HPE lists for it |
| `dell-hpe-servers` | Both servers above in one image (see [One image for several models](#one-image-for-several-models)) |

Build one with:

```bash
scripts/build-variant.sh dell-poweredge-r740xd \
  -var iso_url=/path/to/windows-11-enterprise.iso \
  -var iso_checksum=sha256:<sha256 of the ISO> \
  -var 'image_name=Windows 11 Enterprise'
```

The output is `output-dell-poweredge-r740xd/windows-11-dell-poweredge-r740xd.qcow2`.
Extra arguments are passed to `packer build`.

`build-variant.sh` first runs `scripts/drivers.py fetch`, which:

* downloads each package into `.cache/drivers/` and checks its SHA-256;
* unpacks it, including the vendor installers drivers are wrapped in: zip and
  cab, MSI (through pymsi, keeping real file names), WiX Burn bundles and
  InstallShield setup launchers;
* reads every INF's `[Manufacturer]` section and keeps only drivers Windows 11
  x64 will accept. Server-only INFs (decorated `NTamd64.10.0.3`) are silently
  ignored by Windows 11, so they're dropped and reported rather than staged;
* writes the drivers to `drivers/<variant>/` with a `REPORT.md` listing every
  INF and why it was kept or dropped. Packages marked `boot_critical` go under
  `drivers/<variant>/$WinPEDriver$/` instead (see
  [Boot-critical drivers](#boot-critical-drivers)).

The build then stages every driver into the image, so Windows finds them when
it detects the node's hardware on first boot.

#### One image for several models

A variant can include others:

```toml
[variant]
name = "dell-hpe-servers"
description = "Dell PowerEdge R740xd and HPE ProLiant DL360 Gen10."
includes = ["dell-poweredge-r740xd", "hpe-proliant-dl360-gen10"]
```

`fetch` and `coverage` merge the included variants' packages and devices
(a variant can have its own as well). Each package's drivers go under
`drivers/<variant>/<included variant>/<package>/`, and `coverage` prefixes
device names with the variant they came from. When two included variants use
the same package, each INF is staged once and `REPORT.md` notes the duplicate.

One image for every model is usually the better choice: Windows only binds a
staged driver to hardware that is present, so another vendor's drivers cost
only disk space (the R740xd and DL360 Gen10 drivers add about 120 MB). Use
a per-model variant when a model needs something that conflicts with another
model, such as a different driver version for the same chip: the combined
image would stage both, and Windows would pick one by its own ranking.

#### Boot-critical drivers

A driver staged in the driver store is installed when Windows first detects
the device, which is too late for the controller Windows boots from. If the
boot controller has no inbox Windows 11 driver, mark its package
`boot_critical = true`. `fetch` then writes it to a `$WinPEDriver$` folder at
the root of the build CD, and Windows Setup installs everything there into the
image as a boot driver (service start type boot, ready for the hardware IDs in
its INF), so the deployed node can boot from that controller.

The DL360 Gen10 variant marks its Smart Array S100i software RAID driver
this way. Everything else the included variants can boot from has an inbox
driver, which `coverage` shows.

Before marking a package boot-critical, check which hardware IDs its INF
lists: a boot driver takes every device it matches by hardware ID, ahead of
inbox drivers that only match by class. That is why the R740xd variant leaves
out PERC S140: its driver also lists Dell-branded NVMe drives, so it would
replace the inbox NVMe driver for every such drive, boot drive included.

#### Checking coverage

`coverage` checks that every device listed in a variant has a Windows 11
driver, either inbox (read from the ISO) or staged by the variant:

```bash
sudo mount -o loop,ro /path/to/windows-11-enterprise.iso /mnt/win-iso
.venv/bin/python scripts/drivers.py coverage variants/dell-poweredge-r740xd.toml \
  --inbox /mnt/win-iso/sources/install.wim
sudo umount /mnt/win-iso
```

It exits non-zero if a device has no driver. For the R740xd:

```text
Device                                     Windows 11 inbox             Staged by this variant
PERC H730/H730P (SAS3108)                  megasas2i.inf, percsas3i.inf perc9
PERC H740P/H840 (SAS3508)                  megasas35i.inf               perc10
HBA330 (SAS3008 IT)                        lsi_sas3i.inf                -
BOSS-S1 / onboard SATA (AHCI)              mshdc.inf                    -
Broadcom BCM57414 25GbE                    -                            broadcom-netxtreme-e
QLogic 57800 10GbE                         netevbda.inf                 -
Intel X520 / 82599 10GbE                   -                            intel-x520
Mellanox ConnectX-3 Pro                    mlx4_bus.inf                 -
Mellanox ConnectX-5                        netmlx5.inf                  mellanox-winof2, mellanox-winof2-cx4
Emulex LPe31000/32000 FC                   -                            emulex-fc
...
```

Every R740xd boot controller (PERC 9/10, HBA330, BOSS-S1, NVMe) has a
Windows 11 inbox driver. That matters because a driver staged into the image
is installed too late to boot from. PERC S140 software RAID is listed as an
optional device and isn't covered (see the comment in the variant file).

#### Adding a variant

1. Copy an existing file in `variants/` and fill in `[variant]`, then one
   `[[packages]]` entry per driver package (`id`, `description`, `url`,
   `sha256`, and optionally `include`/`exclude` patterns to pick INFs, and
   `required = false`). Patterns use Python `fnmatch` against each INF's path
   inside the unpacked package: case-sensitive, and `*` also matches `/`.
   The file name must match `[variant] name`.
2. To find packages for Dell servers, `drivers.py dell-catalog` lists the newest Windows driver
   package per family for a system ID, ready to paste. The system ID is the
   `SKU` in the node's Ironic inventory, e.g. `SKU=0737` for the R740xd:

   ```bash
   .venv/bin/python scripts/drivers.py dell-catalog --system-id 0737
   ```

   Dell supports Windows Server, not Windows 11, on PowerEdge, so these are
   Server 2022/2025 packages; `fetch` reports which of their INFs Windows 11
   accepts. For Dell clients and workstations, use the per-model Windows 11
   driver packs in `https://downloads.dell.com/catalog/DriverPackCatalog.cab`,
   as `variants/dell-precision-7960-rack.toml` does.

   For HPE servers, use the Smart Components (`cpNNNNNN.exe`) HPE lists for
   the model: search for it at <https://support.hpe.com>, choose *Drivers and
   Software* and Windows Server 2022 or 2025, and keep the drivers (not
   firmware or management agents). Each component's page gives a stable
   `downloads.hpe.com/pub/softlib2/...` URL and its SHA-256. The Service Pack
   for ProLiant lists the same components. As with Dell, these are Windows
   Server drivers, and some components are wrapped in installers `drivers.py`
   can't unpack (e.g. HPE's Emulex kit); `variants/hpe-proliant-dl360-gen10.toml`
   uses the same driver from another vendor's package instead.
3. Add `[[devices]]` entries with the PCI IDs (`PCI\VEN_xxxx&DEV_xxxx`) or class
   codes (`PCI\CC_xxxxxx`) of the hardware the model can contain, run `fetch`
   and `coverage`, and read `drivers/<variant>/REPORT.md`.

`drivers.py check-infs DIR` reports which INFs under any directory Windows 11
would accept, e.g. for drivers downloaded by hand.

#### Without a variant

Every `.inf` under `vendor_drivers_dir` (default `drivers/vendor-drivers/`)
is staged, so hand-extracted drivers can also go there. They must be 64-bit,
accepted by Windows 11 (check with `drivers.py check-infs`) and
Microsoft-signed. Keep names under 64 characters and paths under 120: the
build CD uses Joliet names, and longer ones are left off the CD.

### What the build does

1. Boots the ISO under OVMF on q35 with a SATA disk and an e1000e NIC. Windows
   has inbox drivers for both, so nothing is injected into WinPE.
2. Windows Setup reads `autounattend.xml` from a generated CD (label
   `PACKERCD`). It skips the Windows 11 TPM/Secure Boot/CPU checks for the
   build VM and partitions the disk as GPT: ESP, MSR, a 1 GB WinRE partition,
   then C: taking the rest. C: is last so it can be extended on deploy;
   without the WinRE partition, Setup shrinks C: to create one after it.
   Instead of running OOBE, Setup boots into **audit mode** and signs in as
   Administrator. Audit mode is how Microsoft intends client images to be
   customised: the build never creates OOBE's temporary account or per-user
   app state for build accounts. Images customised after OOBE give the first
   user to sign in on a deployed node a broken taskbar: Explorer crashes and
   the screen stays black after the "Almost there" screen.
3. At that audit-mode sign-in, `setup-winrm.ps1` runs from the CD and Packer
   connects over WinRM.
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
5. Packer's shutdown command runs `sysprep.ps1`. It starts itself again
   through WMI (`Win32_Process.Create`) and returns, because Windows kills
   processes started from a WinRM shell when Packer closes it. (A scheduled
   task doesn't work: Task Scheduler queues tasks while audit mode is in
   progress.) The second run:
   * Removes AppX packages installed for a user but not provisioned, which
     break Windows 11 sysprep.
   * Removes the build-only Windows Update and Store auto-update policies and
     the autologon. Consumer features stay disabled.
   * Removes the WinRM HTTP listener, Basic auth, unencrypted access and the
     build's WinRM firewall rule, and disables the inbox WinRM HTTP rules.
   * Restores UAC remote restrictions (unless `remote_local_admin` is set),
     which `Enable-PSRemoting` turned off.
   * Gives the built-in Administrator a random password and disables it
     (unless `cloudbase_init_username` is `Administrator`).
   * Deletes Setup's cached copies of the build answer file, which hold the
     build password in plain text.
   * Resets cloudbase-init state.
   * Runs `sysprep /generalize /oobe /shutdown` with
     `templates/sysprep-unattend.xml.pkrtpl`, which powers the VM off.

### On first boot of a deployed node

* In the specialize pass, the build's `sysprep.ps1` is deleted, then
  cloudbase-init reads the Ironic config drive. It creates the `Admin`
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

## Configuring nodes with user data

cloudbase-init runs the instance's user data once per instance, as
LocalSystem, on the boot after it sets the hostname (that reboot happens
during the first boot), by which time the network, `Admin` and its password
are set up. The first line chooses how it is run, and must be the very first
bytes of the file: a UTF-8 byte order mark, which some Windows editors add,
makes cloudbase-init log "Unsupported user_data format" and skip it.

| First line | Run as |
|---|---|
| `#ps1_sysnative` or `#ps1` | 64-bit PowerShell script (`#ps1_x86` for 32-bit) |
| `rem cmd` | `cmd.exe` batch script |
| `#cloud-config` | YAML: the subset of cloud-init modules listed below |
| `Content-Type: multipart/mixed` | Several of the above, run in order |

Output and errors go to
`C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`
(and the node's serial console). A script's exit code can ask for a reboot:
1001 reboots and doesn't run the script again, 1002 runs it again at the next
boot without rebooting, and 1003 reboots and runs it again. Any other code
ends it.

User data is readable by anyone who can read the instance's metadata, so
don't put long-lived secrets in it. cloudbase-init also accepts gzipped user
data.

### PowerShell

`setup.ps1`:

```powershell
#ps1_sysnative
# Runs once, as LocalSystem, after cloudbase-init has set the hostname,
# network and the Admin account. Output goes to cloudbase-init's log.
$ErrorActionPreference = 'Stop'

# High performance power plan: no sleeping, no CPU parking.
powercfg.exe /setactive SCHEME_MIN
if ($LASTEXITCODE) { throw "powercfg failed: $LASTEXITCODE" }

# Let monitoring ping the node. (Checked first so the script can be re-run.)
if (-not (Get-NetFirewallRule -Name 'site-icmpv4-echo' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'site-icmpv4-echo' -DisplayName 'Allow ICMPv4 echo' `
    -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow | Out-Null
}

# Software from an internal repository (example URL):
# Invoke-WebRequest -Uri 'https://repo.example.com/agent.msi' -OutFile "$env:TEMP\agent.msi" -UseBasicParsing
# Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\agent.msi`" /qn" -Wait

New-Item -ItemType Directory -Path 'C:\ProgramData\Site' -Force | Out-Null
Set-Content -Path 'C:\ProgramData\Site\deployed.txt' -Value "Deployed $(Get-Date -Format o) as $env:COMPUTERNAME"
```

With Nova:

```bash
openstack server create my-node \
  --image windows-11-ironic --flavor <baremetal-flavor> --network <network> \
  --config-drive true --property admin_pass='<password>' \
  --user-data setup.ps1
```

With standalone Ironic, put the script in the config drive. cloudbase-init
records what it has run against the `uuid`, so give each deployment a new one:

```bash
openstack baremetal node deploy <node> \
  --config-drive "$(jq -n --rawfile ud setup.ps1 --arg uuid "$(uuidgen)" \
      '{meta_data: {uuid: $uuid, hostname: "my-node", admin_pass: "<password>"}, user_data: $ud}')"
```

### cloud-config

cloudbase-init supports these cloud-config keys on Windows: `write_files`,
`timezone` (IANA names), `ntp`, `hostname`, `users`, `groups` and `runcmd`.
They run in that fixed order, whatever the order in the file. `runcmd`
entries are joined into one `cmd.exe` batch script, not run by a POSIX
shell.

`cloud-config.yaml`:

```yaml
#cloud-config
timezone: Europe/London
ntp:
  enabled: true
  servers:
    - 0.uk.pool.ntp.org
    - 1.uk.pool.ntp.org
write_files:
  - path: C:\ProgramData\Site\settings.json
    content: |
      {"environment": "production"}
# runcmd entries run as one cmd.exe batch script.
runcmd:
  - reg add HKLM\SOFTWARE\Site /v Role /t REG_SZ /d compute /f
  - netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes
```

Pass it with `--user-data cloud-config.yaml` as above.

### Both at once

To use cloud-config and a PowerShell script together, combine them into a
MIME multipart file. The parts run in order. A script part needs a file name:
cloudbase-init skips a script part without one, and picks the interpreter
from its extension (`.ps1` for 64-bit PowerShell, `.cmd` for `cmd.exe`).
A part that exits 1001 or 1003 stops the parts after it for good, so put a
script that asks for a reboot last. Set the time zone in one place only: after
cloud-config `timezone` has run, cloudbase-init (1.1.8) has dropped the
time-zone privilege, so `Set-TimeZone` in a later script part fails with "A
required privilege is not held by the client".

```bash
python3 - <<'EOF'
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
msg = MIMEMultipart()
msg.attach(MIMEText(open("cloud-config.yaml").read(), "cloud-config"))
script = MIMEText(open("setup.ps1").read(), "x-shellscript")
script.add_header("Content-Disposition", "attachment", filename="setup.ps1")
msg.attach(script)
open("user-data.mime", "w").write(msg.as_string())
EOF
openstack server create ... --user-data user-data.mime
```

Nova limits user data to 64 KB after base64 encoding, so about 48 KB of
script, or more if gzipped. The limit doesn't apply to a standalone Ironic
config drive. For anything larger, have the script download it.

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

If a deployment misbehaves, copy `scripts/collect-diagnostics.ps1` to the node
and run it in an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File collect-diagnostics.ps1
```

It writes `C:\diag-<host>-<time>.zip` containing:

* the Windows Setup and sysprep logs;
* the cloudbase-init logs and config;
* the setup state, accounts, disks, network and devices without drivers;
* a metadata-service reachability check;
* the last three days of event logs.

It doesn't collect passwords on purpose, but the cloudbase-init logs include
the output of user-data scripts: check them before sharing if your user data
handles secrets.

## Licensing and redistribution

This repository holds only scripts, templates and documentation. It contains
no Windows media, drivers or other third-party binaries: the build downloads
them from their publishers, pinned by URL and SHA-256. The repository is
licensed under the [Apache License 2.0](LICENSE); that covers this code only,
not anything the build downloads or the images it produces.

* **Product keys.** The keys in `windows-11-ironic.pkr.hcl` are Microsoft's
  public [KMS client keys (GVLKs)](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys),
  published for exactly this use. They don't license or activate Windows: a
  node activates only against your organisation's KMS host or through
  Active Directory-based activation. Set `product_key` to use a MAK instead.
* **Built images are not redistributable.** An image contains Windows,
  licensed under your agreement with Microsoft (images built from the
  Evaluation ISO are licensed only for time-limited evaluation, not
  production use). Windows alone makes an image non-redistributable. It also
  contains cloudbase-init (Apache 2.0), the Red Hat-signed virtio-win guest
  tools, and Dell and HPE driver packages, whose licences permit use but not
  general redistribution. Keep images inside your organisation, e.g. as a
  private (not public or shared) Glance image. If users from other
  organisations can deploy it, as in a multi-tenant cloud, check Microsoft's
  terms for hosting Windows client editions first.
* **Dell packages on HPE servers.** The HPE variant takes the Emulex and
  Intel X520/X540 drivers from Dell's packages, because HPE's are missing or
  can't be unpacked. Dell's [EULA](https://www.dell.com/aeula) says to "run
  the Software only on the hardware for which it was intended to operate,
  when applicable". Third-party software in a Dell package is instead
  governed by its own terms (section 5), but neither package gives you
  separate rights: the Emulex package has no Broadcom licence, and the
  Intel package carries an OEM licence that only takes effect under a
  non-disclosure agreement with Intel. Using them on HPE servers may fall
  outside Dell's terms, so before deploying on HPE nodes, replace both with
  the drivers from Broadcom's and Intel's own download sites, or confirm the
  terms with Dell (tracked in [TODO.md](TODO.md)).
* **Build tools** are installed separately and not redistributed. They
  include Packer (BUSL 1.1), its QEMU plugin (MPL 2.0), QEMU (GPL 2.0),
  OVMF/EDK II (BSD-2-Clause-Patent), xorriso (GPL 3.0 or later), wimlib
  (GPL 3.0 or later, or LGPL 3.0 or later), 7-Zip (LGPL 2.1 or later, with
  BSD-licensed parts and the unRAR restriction), jq (MIT), and `pymsi` (MIT)
  and `olefile` (BSD 2-clause) from PyPI.

## Limitations

* **Boot-critical storage drivers are untested on hardware.** Booting from
  Smart Array S100i software RAID relies on the
  [`boot_critical`](#boot-critical-drivers) install, which has been checked in
  the image but not on a node. PERC S140 software RAID is not supported. Intel VROC RAID on the Precision 7960 comes in
  a driver pack that isn't marked boot-critical, so booting from it may fail
  with `INACCESSIBLE_BOOT_DEVICE`.
* **Variant drivers are checked, not hardware-tested.** `fetch` checks that
  Windows 11 accepts each INF, and `coverage` that each listed device has a
  driver, but neither proves the hardware works: test a deploy on each new
  configuration. Some vendor packages are Windows Server builds running on a
  client OS (see `drivers/<variant>/REPORT.md` for each INF's decoration).
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
* **Build time.** Builds take about 55–60 minutes on a nested-KVM host and
  need internet access for the virtio-win and cloudbase-init downloads.
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
