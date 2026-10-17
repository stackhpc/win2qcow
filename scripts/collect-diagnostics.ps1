# Collects first-boot diagnostics from a deployed node into one zip.
#
# Run in an elevated PowerShell on the node:
#   powershell -ExecutionPolicy Bypass -File collect-diagnostics.ps1
# and send the zip it prints. It doesn't collect passwords on purpose:
# cloudbase-init doesn't log admin_pass, and metadata is only checked for
# reachability, not saved. But the cloudbase-init logs include user-data script
# output, so check them before sharing if your user data handles secrets.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$name = "diag-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmmss)"
$out = Join-Path $env:SystemRoot "Temp\$name"
New-Item -ItemType Directory -Path "$out\files" -Force | Out-Null

function Save([string]$File, [scriptblock]$Command) {
  try { & $Command 2>&1 | Out-String -Width 300 | Set-Content -Path (Join-Path $out $File) -Encoding UTF8 }
  catch { "failed: $_" | Set-Content -Path (Join-Path $out $File) }
}

# Logs and config files.
$cloudbase = "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init"
$paths = @(
  "$env:SystemRoot\Panther\setupact.log", "$env:SystemRoot\Panther\setuperr.log",
  "$env:SystemRoot\Panther\UnattendGC", "$env:SystemRoot\Panther\unattend.xml",
  "$env:SystemRoot\System32\Sysprep\Panther",
  "$env:SystemRoot\Temp\sysprep-wrapper.log", "$env:SystemRoot\Temp\setup-winrm.log",
  "$cloudbase\log", "$cloudbase\conf", "$env:SystemRoot\Setup\Scripts",
  "$env:SystemRoot\INF\setupapi.dev.log", "$env:SystemRoot\INF\setupapi.setup.log"
)
foreach ($p in $paths) {
  if (Test-Path $p) {
    $dest = Join-Path $out ("files\" + ($p -replace '^[A-Za-z]:\\', '' -replace '\\', '_'))
    Copy-Item -Path $p -Destination $dest -Recurse -Force -ErrorAction Continue
  }
}

# State.
Save 'system.txt' {
  Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, TotalPhysicalMemory
  Get-CimInstance Win32_OperatingSystem | Format-List Caption, BuildNumber, InstallDate, LastBootUpTime
  Get-CimInstance Win32_BIOS | Format-List Manufacturer, SMBIOSBIOSVersion, SerialNumber
}
Save 'setup-state.txt' {
  Get-ItemProperty HKLM:\SYSTEM\Setup | Format-List SetupType, SystemSetupInProgress, OOBEInProgress, SetupPhase, CmdLine, SystemStartOptions
  Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status' -ErrorAction SilentlyContinue | Format-List
  Get-ChildItem 'HKLM:\SYSTEM\Setup\Status' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name; Get-ItemProperty $_.PSPath | Format-List }
  'ImageState:'; (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
}
Save 'accounts-services.txt' {
  Get-LocalUser | Format-Table Name, Enabled, LastLogon, PasswordLastSet -AutoSize
  Get-LocalGroupMember -Group Administrators -ErrorAction SilentlyContinue | Format-Table Name, PrincipalSource -AutoSize
  Get-Service cloudbase-init, WinRM, Schedule, TermService -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
  "Build sysprep script left over: $(Test-Path "$env:SystemRoot\Temp\sysprep.ps1")"
  Get-ChildItem 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name; ($_ | Get-ItemProperty | Out-String).Trim() }
}
Save 'storage.txt' {
  Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, Size -AutoSize
  Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter, Type, Size -AutoSize
  Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining -AutoSize
  'Config drive volumes (label config-2):'
  Get-Volume | Where-Object FileSystemLabel -eq 'config-2' | Format-Table DriveLetter, FileSystem, Size -AutoSize
}
Save 'network.txt' {
  Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress, LinkSpeed -AutoSize
  ipconfig /all
  route print
  'Metadata service (reachability only, content not saved):'
  foreach ($u in 'http://169.254.169.254/', 'http://169.254.169.254/openstack/latest/meta_data.json') {
    try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 10; "$u -> HTTP $($r.StatusCode), $($r.RawContentLength) bytes" }
    catch { "$u -> $($_.Exception.Message)" }
  }
}
Save 'devices.txt' {
  'Devices with problems:'
  Get-PnpDevice | Where-Object Status -ne 'OK' | Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
  'Network and storage devices:'
  Get-PnpDevice -Class Net, SCSIAdapter, HDC -ErrorAction SilentlyContinue | Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
}
Save 'drivers.txt' { Get-WindowsDriver -Online | Sort-Object OriginalFileName | Format-Table OriginalFileName, ProviderName, Version, ClassName -AutoSize }

# Event logs from the last 3 days.
$since = (Get-Date).AddDays(-3).ToUniversalTime().ToString('s')
foreach ($log in 'System', 'Application', 'Setup', 'Microsoft-Windows-Shell-Core/Operational',
                 'Microsoft-Windows-User Profile Service/Operational', 'Microsoft-Windows-Winlogon/Operational') {
  $file = Join-Path $out ("events-" + ($log -replace '[/ ]', '_') + ".evtx")
  wevtutil epl $log $file "/q:*[System[TimeCreated[@SystemTime>='$since']]]" 2>$null
}

$zip = Join-Path $env:SystemDrive "\$name.zip"
Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
Remove-Item -Path $out -Recurse -Force
Write-Host "Diagnostics written to $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
