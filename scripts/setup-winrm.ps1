# Enables WinRM over HTTP so Packer can connect. Runs from the build CD at
# audit-mode sign-in (see autounattend.xml). sysprep.ps1 undoes this before the image
# is generalized.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemRoot\Temp\setup-winrm.log" -Append

# WinRM refuses to configure itself on Public networks.
Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' |
  Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Continue

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\MaxTimeoutms -Value 1800000
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048

# Audit mode runs this at every sign-in: replace the rule rather than add a duplicate.
Remove-NetFirewallRule -Name 'packer-winrm-http' -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'packer-winrm-http' -DisplayName 'Packer WinRM (HTTP)' `
  -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any

Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM

Stop-Transcript
