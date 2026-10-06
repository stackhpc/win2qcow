# Adds every *.inf on the build CD (from vendor_drivers_dir) to the driver
# store, so the bare-metal NIC and storage controller work after deploy.
$ErrorActionPreference = 'Stop'

$cd = Get-Volume | Where-Object { $_.FileSystemLabel -eq $env:CD_LABEL -and $_.DriveLetter } |
  Select-Object -First 1
if (-not $cd) {
  throw "Build CD with label '$env:CD_LABEL' not found."
}

$infs = Get-ChildItem -Path "$($cd.DriveLetter):\" -Recurse -Filter *.inf -File
if (-not $infs) {
  Write-Host 'No vendor drivers on the build CD.'
  exit 0
}

$failed = @()
foreach ($inf in $infs) {
  Write-Host "Adding $($inf.FullName)"
  & pnputil.exe /add-driver $inf.FullName /install
  # 259: staged, but no matching device in the build VM (expected for bare-metal drivers).
  # 3010: reboot required; the build reboots after this step.
  if ($LASTEXITCODE -notin 0, 259, 3010) {
    $failed += "$($inf.FullName) (exit $LASTEXITCODE)"
  }
}

if ($failed) {
  # Vendor packs often include INFs for other architectures or OS versions,
  # so a failure here is reported rather than fatal.
  Write-Warning "pnputil could not add $($failed.Count) driver(s):"
  $failed | ForEach-Object { Write-Warning "  $_" }
}

Write-Host 'Third-party drivers now in the driver store:'
& pnputil.exe /enum-drivers
exit 0
