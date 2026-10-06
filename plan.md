# Plan: Use Packer to Produce an Ironic-Compatible Windows qcow2 Image

## Goal

Use **Packer + QEMU** to build a **whole-disk Windows qcow2** image that is:

- Ironic-compatible (bare-metal deployable)
- Correct boot mode (BIOS or UEFI)
- Includes VirtIO + vendor drivers
- Includes cloudbase-init
- Sysprepped
- Ready to upload to Glance for Ironic

This is achievable, but you must tune the Packer build for Ironic’s whole-disk and boot-mode requirements.

---

## 1. Key Ironic requirements

For Ironic, the image must be:

- **Whole-disk** (includes bootloader + partitions)
- Match the node’s firmware:
  - `BIOS` or `UEFI`
- Include drivers for:
  - NICs
  - Storage controllers
  - Any other bare-metal hardware
- Include **cloudbase-init** for first-boot configuration
- Be **sysprepped** before upload

Ironic writes the entire image to the bare-metal disk; it does not use partition-only images.

---

## 2. Tooling

Use:

- **Packer** with the **QEMU builder**
- **QEMU/KVM** on a Linux build host
- **Windows ISO**
- **VirtIO drivers ISO**
- **Vendor drivers ISO or directory** for your bare-metal hardware
- **cloudbase-init** (installed during build)

Packer’s QEMU builder supports qcow2 output and can boot Windows ISOs with unattend files.

---

## 3. Directory layout

```text
windows-ironic-packer/
├── windows-server-2025-ironic.pkr.hcl
├── http/
│   └── autounattend.xml
├── scripts/
│   ├── install-virtio.ps1
│   ├── install-vendor-drivers.ps1
│   ├── install-cloudbase-init.ps1
│   ├── configure-cloudbase-init.ps1
│   └── sysprep-and-shutdown.ps1
├── files/
│   └── cloudbase-init.conf
└── drivers/
    └── vendor-drivers/
        ├── nic/
        └── storage/
```

---

## 4. Packer template

### `windows-server-2025-ironic.pkr.hcl`

```hcl
packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "win_iso" {
  type    = string
  default = "/path/to/windows-server-2025.iso"
}

variable "virtio_iso" {
  type    = string
  default = "/path/to/virtio-win.iso"
}

variable "vendor_drivers_dir" {
  type    = string
  default = "./drivers/vendor-drivers"
}

source "qemu" "windows-server-2025-ironic" {
  iso_url          = var.win_iso
  iso_checksum     = "none"
  iso_target_path  = "/var/lib/libvirt/images/windows-server-2025.iso"

  output_directory = "output-windows-server-2025-ironic"
  format           = "qcow2"
  accelerator      = "kvm"
  headless         = true

  cpus             = 4
  memory           = 8192
  disk_size        = "60G"
  disk_interface   = "virtio"
  net_device       = "virtio-net"

  # Boot mode: choose one
  # For UEFI:
  # firmware = "/usr/share/OVMF/OVMF_CODE.fd"
  # For BIOS:
  # (default, no firmware needed)

  # Attach autounattend via HTTP
  http_directory = "http"

  # Attach VirtIO ISO as second CD
  qemuargs = [
    ["-drive", "file=${var.virtio_iso},media=cdrom,index=1"],
  ]

  boot_wait = "10s"
  boot_command = [
    "<wait5><spacebar>"
  ]

  communicator = "winrm"
  winrm_username = "Administrator"
  winrm_password = "P@ssw0rd!"
  winrm_timeout  = "4h"
  winrm_use_ssl  = false
  winrm_insecure = true

  shutdown_command = "powershell -Command \"& 'C:\\Windows\\Temp\\sysprep-and-shutdown.ps1'\""
}

build {
  sources = ["source.qemu.windows-server-2025-ironic"]

  provisioner "powershell" {
    script = "scripts/install-virtio.ps1"
  }

  provisioner "powershell" {
    script = "scripts/install-vendor-drivers.ps1"
  }

  provisioner "powershell" {
    script = "scripts/install-cloudbase-init.ps1"
  }

  provisioner "file" {
    source      = "files/cloudbase-init.conf"
    destination = "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/conf/cloudbase-init.conf"
  }

  provisioner "powershell" {
    script = "scripts/configure-cloudbase-init.ps1"
  }

  provisioner "powershell" {
    script = "scripts/sysprep-and-shutdown.ps1"
  }
}
```

### Notes

- Choose **BIOS or UEFI** to match your Ironic nodes.
- If UEFI:
  - Set `firmware` to OVMF path.
  - Ensure `autounattend.xml` and boot commands work in UEFI mode.
- If BIOS:
  - Default QEMU BIOS is fine.

---

## 5. autounattend.xml

### `http/autounattend.xml`

Must:

- Partition/format disk
- Install correct Windows edition
- Enable Administrator
- Set password
- Enable WinRM
- Optionally run first-logon script

Example skeleton:

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Password>
          <Value>P@ssw0rd!</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>5</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        <AdministratorPassword>
          <Value>P@ssw0rd!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
```

Adjust:

- `DiskID` / `PartitionID`
- Password
- Add `RunSynchronous` commands if installing VirtIO during setup

---

## 6. PowerShell scripts

### `scripts/install-virtio.ps1`

```powershell
$ErrorActionPreference = "Stop"

# Assumes VirtIO ISO is mounted as D:
$virtio = "D:\"

# Install NetKVM driver
pnputil /add-driver "$virtio\NetKVM\2k22\amd64\netkvm.inf" /install

# Install Balloon driver
pnputil /add-driver "$virtio\Balloon\2k22\amd64\balloon.inf" /install

# Install QEMU Guest Agent if present
if (Test-Path "$virtio\guest-agent\qemu-ga-x86_64.msi") {
  Start-Process msiexec.exe -Wait -ArgumentList "/i `"$virtio\guest-agent\qemu-ga-x86_64.msi`" /quiet"
}
```

### `scripts/install-vendor-drivers.ps1`

```powershell
$ErrorActionPreference = "Stop"

# Copy vendor drivers into Windows driver store
$driverRoot = "C:\Windows\Temp\vendor-drivers"

# Assume drivers were copied via Packer file provisioner or shared folder
Get-ChildItem -Path $driverRoot -Recurse -Filter *.inf | ForEach-Object {
  pnputil /add-driver $_.FullName /install
}
```

You must ensure the vendor drivers are available inside the VM (e.g., via ISO, shared folder, or Packer `file` provisioner).

### `scripts/install-cloudbase-init.ps1`

```powershell
$ErrorActionPreference = "Stop"

$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$msi = "$env:TEMP\cloudbaseinit.msi"

Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing

Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /quiet /norestart"
```

### `scripts/configure-cloudbase-init.ps1`

```powershell
$ErrorActionPreference = "Stop"

Set-Service -Name "cloudbase-init" -StartupType Automatic
Restart-Service -Name "cloudbase-init"
```

### `scripts/sysprep-and-shutdown.ps1`

```powershell
$ErrorActionPreference = "Stop"

$sysprep = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$unattend = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"

& $sysprep /generalize /oobe /shutdown /unattend:$unattend
```

---

## 7. cloudbase-init.conf

### `files/cloudbase-init.conf`

```ini
[DEFAULT]
metadata_services=cloudbaseinit.metadata.services.httpservice.HttpService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService
allow_reboot=false
stop_service_on_exit=false
```

Adjust `metadata_services` to match your OpenStack setup.

---

## 8. Build command

```bash
packer init .
packer build \
  -var "win_iso=/path/to/windows-server-2025.iso" \
  -var "virtio_iso=/path/to/virtio-win.iso" \
  -var "vendor_drivers_dir=./drivers/vendor-drivers" \
  windows-server-2025-ironic.pkr.hcl
```

Output:

```text
output-windows-server-2025-ironic/packer-windows-server-2025-ironic
```

This is your qcow2 image.

---

## 9. Upload to Glance for Ironic

```bash
openstack image create "windows-server-2025-ironic" \
  --disk-format qcow2 \
  --container-format bare \
  --file output-windows-server-2025-ironic/packer-windows-server-2025-ironic \
  --property os_type=windows \
  --property hw_disk_bus=virtio \
  --property hw_vif_model=virtio \
  --property hw_firmware_type=uefi \
  --property hw_machine_type=q35
```

Adjust properties to match your Ironic nodes and boot mode.

---

## 10. Ironic-specific validation

After deploying via Ironic:

- Confirm:
  - Node boots correctly
  - Network works
  - cloudbase-init ran
  - Hostname/timezone correct
  - You can RDP in
- Check:
  - `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`
  - Event Viewer → Applications and Services Logs → Cloudbase-Init

---

## 11. Optional: post-build tweaks with virt-customize

If you want to inject extra files or first-boot scripts without rebuilding:

```bash
virt-customize -a output-windows-server-2025-ironic/packer-windows-server-2025-ironic \
  --hostname my-windows-host \
  --timezone "Europe/London" \
  --copy-in /path/to/extra-config.ps1:/Windows/Temp/ \
  --firstboot-command "powershell -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\extra-config.ps1"
```

---

## 12. References

- Ironic Windows image docs:  
  https://docs.openstack.org/ironic/latest/admin/building-windows-images.html
- Packer QEMU builder docs:  
  https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu
- Packer Windows unattended install guide:  
  https://developer.hashicorp.com/packer/guides/automatic-operating-system-installs/autounattend_windows
- Existing Windows Packer templates:
  - https://github.com/proactivelabs/packer-windows
  - https://github.com/rgl/windows-vagrant
  - https://github.com/rolando-anton/packer-disposable-windows
- Cloudbase-init Packer scripts:
  - https://github.com/cloudbase/cloudbase-init-packer-scripts

---

## Bottom line

You **can** use Packer to produce an Ironic-compatible Windows qcow2, provided you:

- Build a **whole-disk image**
- Match the node’s **boot mode** (BIOS or UEFI)
- Include **VirtIO + vendor drivers**
- Install and configure **cloudbase-init**
- Run **sysprep**
- Upload with correct **Ironic properties**
