# Installs virtio-win drivers and guest tools, so the image also runs on KVM
# (useful for testing it before deploying to bare metal).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$url = $env:VIRTIO_WIN_GUEST_TOOLS_URL
if (-not $url) {
  Write-Host 'VIRTIO_WIN_GUEST_TOOLS_URL is empty; skipping virtio-win.'
  exit 0
}

$exe = Join-Path $env:TEMP 'virtio-win-guest-tools.exe'
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

$p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
  '/install', '/quiet', '/norestart',
  '/log', "$env:SystemRoot\Temp\virtio-win-guest-tools.log"
)
if ($p.ExitCode -notin 0, 3010) {
  throw "virtio-win-guest-tools failed with exit code $($p.ExitCode); see $env:SystemRoot\Temp\virtio-win-guest-tools.log"
}
Remove-Item $exe
