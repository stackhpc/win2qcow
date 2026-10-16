# Packer's shutdown_command.
#
# Run over WinRM (no arguments), it starts this script again with -Generalize
# through WMI (Win32_Process.Create), then returns. Sysprep must not run inside
# the WinRM shell: Windows kills the shell's processes when Packer closes it.
# A WMI-created process is outside that job. (A scheduled task would be too,
# but Task Scheduler queues tasks while audit mode's OOBE is in progress.)
#
# Run with -Generalize, it removes everything that only existed for the build,
# then runs sysprep, which powers the VM off.
param(
  [switch]$Generalize,
  [switch]$DisableBuiltinAdmin
)

if (-not $Generalize) {
  $ErrorActionPreference = 'Stop'
  $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Generalize"
  if ($DisableBuiltinAdmin) { $command += ' -DisableBuiltinAdmin' }
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command }
  if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed with $($r.ReturnValue)" }
  Write-Host "Started sysprep (pid $($r.ProcessId)); it will power the VM off."
  exit 0
}

# Clean-up below is best effort: a failure must not stop sysprep from running,
# or Packer just waits for shutdown_timeout.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path "$env:SystemRoot\Temp\sysprep-wrapper.log" -Append

$cloudbase = "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init"

# Windows 11 sysprep fails if an AppX package is installed for a user but not
# provisioned for all users. Remove only such packages, never frameworks: the
# shell depends on some (e.g. WindowsAppRuntime), and removing them makes
# Explorer crash for every new user, which fails OOBE on deployed nodes.
$provisioned = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty DisplayName
Get-AppxPackage -AllUsers |
  Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' -and $_.Name -notin $provisioned } |
  ForEach-Object {
    Write-Host "Removing per-user AppX package $($_.PackageFullName)"
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop } catch { Write-Warning $_ }
  }

# Undo build-only policies so deployed nodes update Windows and Store apps.
# DisableWindowsConsumerFeatures is kept deliberately: no consumer apps on nodes.
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
  -Name NoAutoUpdate -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
  -Name AutoDownload -ErrorAction SilentlyContinue

# Build-time autologon.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -Path $winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue

# Cached copies of the build answer file, which hold the build password in
# plain text (unattend-original.xml is Setup's untouched copy).
Remove-Item -Path "$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\unattend-original.xml", `
  "$env:SystemRoot\Panther\Unattend" -Recurse -Force -ErrorAction SilentlyContinue

# Build-time WinRM: HTTP listener, Basic auth, unencrypted traffic and the
# firewall rules opened by setup-winrm.ps1 / Enable-PSRemoting. Packer's
# session is already closed. cloudbase-init sets up an HTTPS listener on the
# deployed node.
Start-Service -Name WinRM
Get-ChildItem WSMan:\localhost\Listener |
  Where-Object { $_.Keys -contains 'Transport=HTTP' } |
  Remove-Item -Recurse -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
Remove-NetFirewallRule -Name 'packer-winrm-http' -ErrorAction SilentlyContinue
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule

# The built-in Administrator has the build password: randomise it, and disable
# it unless cloudbase-init manages that account.
$admin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' }
$chars = [char[]](33..126)
$password = -join (1..32 | ForEach-Object { $chars | Get-Random })
$admin | Set-LocalUser -Password (ConvertTo-SecureString $password -AsPlainText -Force)
if ($DisableBuiltinAdmin) { $admin | Disable-LocalUser }

# cloudbase-init must start from a clean slate on the deployed node.
Get-ChildItem -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force
Remove-Item -Path "$cloudbase\log\*" -Force -ErrorAction SilentlyContinue

# This script is removed in the specialize pass on the deployed node
# (see sysprep-unattend.xml).
# Audit mode opens the Sysprep window at sign-in; only one instance can run.
Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host 'Running sysprep'
Stop-Transcript
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /quiet "/unattend:$cloudbase\conf\Unattend.xml"
