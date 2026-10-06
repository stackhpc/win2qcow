$ErrorActionPreference = 'Stop'

# Remote Desktop, with Network Level Authentication.
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty -Path $ts -Name fDenyTSConnections -Value 0
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# Stop Windows 11 turning on BitLocker device encryption by itself on nodes
# that have a TPM. Ironic would then be unable to recover or re-image them
# cleanly, and nobody would hold the recovery key.
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' `
  -Name PreventDeviceEncryption -Type DWord -Value 1

# Servers, not laptops: no sleep, no hibernation file.
& powercfg.exe /setactive SCHEME_MIN
& powercfg.exe /change standby-timeout-ac 0
& powercfg.exe /change monitor-timeout-ac 0
& powercfg.exe /hibernate off

# Where the file provisioner puts SetupComplete.cmd.
New-Item -Path "$env:SystemRoot\Setup\Scripts" -ItemType Directory -Force | Out-Null
