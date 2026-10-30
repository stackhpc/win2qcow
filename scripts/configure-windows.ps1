$ErrorActionPreference = 'Stop'

# Remote Desktop, with Network Level Authentication.
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty -Path $ts -Name fDenyTSConnections -Value 0
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# Stop Windows 11 turning on BitLocker device encryption by itself on nodes
# that have a TPM: nobody would hold the recovery key, so a node that lands
# on the recovery screen (e.g. after a firmware change) could only be
# redeployed. Deliberate BitLocker is the bitlocker build option instead.
# (New-Item -Force on an existing registry key deletes and recreates it.)
$bitlocker = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
if (-not (Test-Path $bitlocker)) { New-Item -Path $bitlocker | Out-Null }
Set-ItemProperty -Path $bitlocker -Name PreventDeviceEncryption -Type DWord -Value 1

# Smart App Control starts in evaluation mode and may later switch itself on
# and block unsigned code (e.g. cloudbase-init user data scripts). Turn it off;
# it can only be re-enabled by reinstalling Windows.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
  -Name VerifiedAndReputablePolicyState -Type DWord -Value 0

# Servers, not laptops: no sleep, no hibernation file.
foreach ($a in @('/setactive', 'SCHEME_MIN'), @('/change', 'standby-timeout-ac', '0'),
                @('/change', 'monitor-timeout-ac', '0'), @('/hibernate', 'off')) {
  & powercfg.exe @a
  if ($LASTEXITCODE -ne 0) { throw "powercfg $($a -join ' ') failed with exit code $LASTEXITCODE" }
}

# Where the file provisioner puts SetupComplete.cmd.
New-Item -Path "$env:SystemRoot\Setup\Scripts" -ItemType Directory -Force | Out-Null

# Packer uses the last native exit code as the step result.
exit 0
