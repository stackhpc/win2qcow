# Installs virtio-win drivers and guest tools, so the image also runs on KVM
# (useful for testing it before deploying to bare metal).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# fedorapeople and others sit behind an anti-bot proxy that serves a challenge
# page to browser-like user agents, which includes PowerShell's default.
function Get-VerifiedDownload([string]$Url, [string]$Sha256, [string]$OutFile) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -UserAgent 'windows-image-build'
  $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
  if ($actual -ne $Sha256) {
    throw "SHA-256 mismatch for ${Url}: expected $Sha256, got $actual"
  }
}

$url = $env:VIRTIO_WIN_GUEST_TOOLS_URL
if (-not $url) {
  Write-Host 'VIRTIO_WIN_GUEST_TOOLS_URL is empty; skipping virtio-win.'
  exit 0
}

$exe = Join-Path $env:TEMP 'virtio-win-guest-tools.exe'
Get-VerifiedDownload -Url $url -Sha256 $env:VIRTIO_WIN_GUEST_TOOLS_SHA256 -OutFile $exe

$p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
  '/install', '/quiet', '/norestart',
  '/log', "$env:SystemRoot\Temp\virtio-win-guest-tools.log"
)
if ($p.ExitCode -notin 0, 3010) {
  throw "virtio-win-guest-tools failed with exit code $($p.ExitCode); see $env:SystemRoot\Temp\virtio-win-guest-tools.log"
}
Remove-Item $exe
