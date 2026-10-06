# Packer's shutdown_command. Final clean-up, then sysprep, which powers the VM off.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemRoot\Temp\sysprep-wrapper.log" -Append

$cloudbase = "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init"

# Windows 11 sysprep fails if any AppX package is installed for a user but not
# provisioned for all users. Remove such packages.
$provisioned = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty PackageName
Get-AppxPackage -AllUsers |
  Where-Object { -not $_.NonRemovable -and $_.SignatureKind -ne 'System' -and $_.PackageFullName -notin $provisioned } |
  ForEach-Object {
    Write-Host "Removing per-user AppX package $($_.PackageFullName)"
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers } catch { Write-Warning $_ }
  }

# Undo the build-only Windows Update policy so deployed nodes update.
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
  -Name NoAutoUpdate -ErrorAction SilentlyContinue

# Build-time autologon.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -Path $winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue

# Cached copies of the build answer file.
Remove-Item -Path "$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\Unattend" `
  -Recurse -Force -ErrorAction SilentlyContinue

# cloudbase-init must start from a clean slate on the deployed node.
Get-ChildItem -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force
Remove-Item -Path "$cloudbase\log\*" -Force -ErrorAction SilentlyContinue

# Start sysprep without waiting: it shuts the VM down, which would otherwise
# drop the WinRM connection mid-command.
Write-Host 'Starting sysprep'
Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" -ArgumentList @(
  '/generalize', '/oobe', '/shutdown', '/quiet', "/unattend:`"$cloudbase\conf\Unattend.xml`""
)

Stop-Transcript
