# Stages every *.inf on the build CD (from vendor_drivers_dir) in the driver
# store, so the bare-metal NIC and storage controller work after deploy.
# Drivers are staged, not installed: they are for hardware the build VM does
# not have, and installing one against a matching emulated device (e.g. an
# Intel chipset INF against QEMU's ICH9) could break the build VM.
$ErrorActionPreference = 'Stop'

$cd = Get-Volume | Where-Object { $_.FileSystemLabel -eq $env:CD_LABEL -and $_.DriveLetter } |
  Select-Object -First 1
if (-not $cd) {
  throw "Build CD with label '$env:CD_LABEL' not found."
}

$root = "$($cd.DriveLetter):\"
# -Filter also matches 8.3 short names (e.g. foo.inf_), so check the extension.
$infs = @(Get-ChildItem -Path $root -Recurse -Filter *.inf -File | Where-Object Extension -eq '.inf')

# A variant build (scripts/drivers.py) puts manifest.json on the CD and has
# already dropped every INF Windows 11 would reject, so any failure here is a
# real problem: fail the build. Hand-placed drivers are only warned about.
# Only the CD root's manifest counts: vendor payloads may have their own.
$manifest = Join-Path $root 'manifest.json'
$strict = Test-Path -Path $manifest -PathType Leaf
if ($strict) {
  $expected = 0
  $packages = Get-Content $manifest -Raw | ConvertFrom-Json
  foreach ($pkg in $packages) { foreach ($i in $pkg.infs) { if ($i.applies) { $expected++ } } }
  if ($infs.Count -ne $expected) {
    throw "Build CD has $($infs.Count) INFs but the variant manifest lists ${expected}: files were lost or renamed on the CD."
  }
}

if (-not $infs) {
  Write-Host 'No vendor drivers on the build CD.'
  exit 0
}

$failed = @()
foreach ($inf in $infs) {
  Write-Host "Adding $($inf.FullName)"
  & pnputil.exe /add-driver $inf.FullName
  # 3010: reboot required; the build reboots after this step.
  if ($LASTEXITCODE -notin 0, 3010) {
    $failed += "$($inf.FullName) (exit $LASTEXITCODE)"
  }
}

Write-Host 'Third-party drivers now in the driver store:'
& pnputil.exe /enum-drivers

if ($failed) {
  $failed | ForEach-Object { Write-Warning "pnputil could not add $_" }
  if ($strict) { throw "$($failed.Count) variant driver(s) could not be staged; see above." }
}
exit 0
