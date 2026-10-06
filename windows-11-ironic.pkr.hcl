packer {
  required_plugins {
    qemu = {
      # shutdown_command behaviour depends on the plugin/SDK version; see sysprep.ps1.
      version = "~> 1.1.7"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

variable "iso_url" {
  type        = string
  description = "Path or URL of the Windows 11 Enterprise ISO."
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "ISO checksum, e.g. \"sha256:abc...\" or \"file:./SHA256SUMS\"."
}

variable "image_name" {
  type        = string
  default     = "Windows 11 Enterprise"
  description = "Value of /IMAGE/NAME in install.wim. Evaluation media uses \"Windows 11 Enterprise Evaluation\". List with: wiminfo sources/install.wim"
}

variable "product_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Product key for setup. Empty: none for evaluation images, otherwise the public Windows 11 Enterprise KMS client key (GVLK)."
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Built-in Administrator password, used only by WinRM during the build. Randomised before sysprep. Set per build, e.g. PKR_VAR_build_password."
}

variable "ui_language" {
  type        = string
  default     = "en-GB"
  description = "Must be a language present on the ISO."
}

variable "input_locale" {
  type    = string
  default = "en-GB"
}

variable "system_locale" {
  type    = string
  default = "en-GB"
}

variable "user_locale" {
  type    = string
  default = "en-GB"
}

variable "timezone" {
  type        = string
  default     = "UTC"
  description = "Windows time zone ID, e.g. \"GMT Standard Time\"."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type        = string
  default     = "40G"
  description = "Virtual disk size. Ironic target disks must be at least this big; C: is extended to fill the disk on deploy."
}

variable "qemu_binary" {
  type    = string
  default = "/usr/libexec/qemu-kvm"
}

variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
}

variable "efi_firmware_vars" {
  type    = string
  default = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
}

variable "vendor_drivers_dir" {
  type        = string
  default     = ""
  description = "Directory of extracted vendor drivers (*.inf trees) for the bare-metal hardware, shipped to the VM on the build CD. Empty: drivers/vendor-drivers in this repo."
}

variable "virtio_win_guest_tools_url" {
  type        = string
  default     = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-guest-tools.exe"
  description = "virtio-win guest tools installer. Set to \"\" to skip (not needed for bare metal only)."
}

variable "virtio_win_guest_tools_sha256" {
  type        = string
  default     = "d8ae9ea1e943384ac195e012cd36f82c3161620e5fc9529be4e42e6f420e222d"
  description = "SHA-256 of virtio_win_guest_tools_url. The installer is not Authenticode-signed."
}

variable "cloudbase_init_url" {
  type    = string
  default = "https://cloudbase.it/downloads/CloudbaseInitSetup_1_1_8_x64.msi"
}

variable "cloudbase_init_sha256" {
  type    = string
  default = "0e7fa42e0cbc0ce7657f85730b0c6cc7afc4087a3639df0ff51a721a0be19bd5"
}

variable "cloudbase_init_username" {
  type        = string
  default     = "Admin"
  description = "Local admin account cloudbase-init creates on the deployed node and sets the password of."
}

variable "headless" {
  type    = bool
  default = true
}

variable "output_directory" {
  type    = string
  default = "output-windows-11-ironic"
}

variable "vm_name" {
  type    = string
  default = "windows-11-ironic.qcow2"
}

# ---------------------------------------------------------------------------

locals {
  # Label of the generated CD carrying autounattend.xml, setup-winrm.ps1 and
  # vendor drivers. Scripts locate the CD by this label.
  cd_label = "PACKERCD"

  # Absolute: Packer's cd_files mishandles directories given as "./dir".
  vendor_drivers_dir = abspath(var.vendor_drivers_dir != "" ? var.vendor_drivers_dir : "${path.root}/drivers/vendor-drivers")

  cloudbase_init_dir = "C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init"

  # Without a key, Setup stops at the product key page on non-evaluation media.
  windows_11_enterprise_gvlk = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
  product_key = (var.product_key != "" ? var.product_key :
  strcontains(var.image_name, "Evaluation") ? "" : local.windows_11_enterprise_gvlk)

  # Values substituted into XML must be escaped.
  xml_build_password = replace(replace(replace(var.build_password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

  locale = {
    ui_language   = var.ui_language
    input_locale  = var.input_locale
    system_locale = var.system_locale
    user_locale   = var.user_locale
    timezone      = var.timezone
  }

  cloudbase_init_conf_vars = {
    install_dir = local.cloudbase_init_dir
    username    = var.cloudbase_init_username
  }
}

source "qemu" "windows-11-ironic" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  qemu_binary  = var.qemu_binary
  accelerator  = "kvm"
  machine_type = "q35"
  # Windows 11 24H2+ needs SSE4.2/POPCNT; QEMU's default qemu64 model lacks them.
  cpu_model = "host"
  cpus      = var.cpus
  memory    = var.memory

  # UEFI only. Ironic must deploy this image to nodes in UEFI boot mode.
  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  efi_drop_efivars  = true

  # Whole-disk qcow2. "ide" is the q35 AHCI (SATA) controller, which Windows
  # Setup supports natively, so no storage driver needs injecting into WinPE.
  format             = "qcow2"
  disk_size          = var.disk_size
  disk_interface     = "ide"
  disk_cache         = "unsafe"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true

  # e1000e has an inbox Windows driver. "romfile=" removes its PXE option ROM so
  # OVMF goes straight to the install CD instead of trying network boot first.
  net_device = "e1000e,romfile="

  # Same as the plugin's default netdev, but the WinRM port forward listens on
  # 127.0.0.1 only rather than on every host interface.
  qemuargs = [
    ["-netdev", "user,id=user.0,hostfwd=tcp:127.0.0.1:{{ .SSHHostPort }}-:5985"],
  ]

  # Windows Setup picks up autounattend.xml from the root of any CD.
  cd_label = local.cd_label
  cd_files = [
    "${path.root}/scripts/setup-winrm.ps1",
    local.vendor_drivers_dir,
  ]
  cd_content = {
    "autounattend.xml" = templatefile("${path.root}/templates/autounattend.xml.pkrtpl", merge(local.locale, {
      image_name     = var.image_name
      product_key    = local.product_key
      admin_password = local.xml_build_password
    }))
  }

  # Answer the UEFI "Press any key to boot from CD or DVD" prompt.
  boot_wait    = "2s"
  boot_command = ["<spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar><wait><spacebar>"]

  headless         = var.headless
  vnc_bind_address = "127.0.0.1"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.build_password
  winrm_timeout  = "2h"
  winrm_use_ssl  = false
  winrm_insecure = true

  # sysprep.ps1 is uploaded by the last provisioner. It hands sysprep to a
  # scheduled task (outside the WinRM shell) and returns; sysprep powers the VM
  # off when done.
  shutdown_command = join(" ", compact([
    "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\sysprep.ps1",
    lower(var.cloudbase_init_username) != "administrator" ? "-DisableBuiltinAdmin" : "",
  ]))
  shutdown_timeout = "1h"

  output_directory = var.output_directory
  vm_name          = var.vm_name
}

build {
  sources = ["source.qemu.windows-11-ironic"]

  provisioner "powershell" {
    script = "${path.root}/scripts/configure-windows.ps1"
  }

  provisioner "powershell" {
    environment_vars = [
      "VIRTIO_WIN_GUEST_TOOLS_URL=${var.virtio_win_guest_tools_url}",
      "VIRTIO_WIN_GUEST_TOOLS_SHA256=${var.virtio_win_guest_tools_sha256}",
    ]
    script = "${path.root}/scripts/install-virtio.ps1"
  }

  provisioner "powershell" {
    environment_vars = ["CD_LABEL=${local.cd_label}"]
    script           = "${path.root}/scripts/install-vendor-drivers.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # cloudbase-init is installed after the last reboot so its service never runs
  # during the build.
  provisioner "powershell" {
    environment_vars = [
      "CLOUDBASE_INIT_URL=${var.cloudbase_init_url}",
      "CLOUDBASE_INIT_SHA256=${var.cloudbase_init_sha256}",
      "CLOUDBASE_INIT_USERNAME=${var.cloudbase_init_username}",
    ]
    script = "${path.root}/scripts/install-cloudbase-init.ps1"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/templates/cloudbase-init.conf.pkrtpl", local.cloudbase_init_conf_vars)
    destination = "${local.cloudbase_init_dir}\\conf\\cloudbase-init.conf"
  }

  provisioner "file" {
    content     = templatefile("${path.root}/templates/cloudbase-init-unattend.conf.pkrtpl", local.cloudbase_init_conf_vars)
    destination = "${local.cloudbase_init_dir}\\conf\\cloudbase-init-unattend.conf"
  }

  provisioner "file" {
    content = templatefile("${path.root}/templates/sysprep-unattend.xml.pkrtpl", merge(local.locale, {
      install_dir = local.cloudbase_init_dir
    }))
    destination = "${local.cloudbase_init_dir}\\conf\\Unattend.xml"
  }

  # Runs once on the deployed node after OOBE: enables the cloudbase-init service.
  provisioner "file" {
    source      = "${path.root}/files/SetupComplete.cmd"
    destination = "C:\\Windows\\Setup\\Scripts\\SetupComplete.cmd"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/cleanup.ps1"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/sysprep.ps1"
    destination = "C:\\Windows\\Temp\\sysprep.ps1"
  }
}
