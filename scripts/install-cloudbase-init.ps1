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

$msi = Join-Path $env:TEMP 'CloudbaseInitSetup.msi'
$log = "$env:SystemRoot\Temp\cloudbase-init-install.log"

Get-VerifiedDownload -Url $env:CLOUDBASE_INIT_URL -Sha256 $env:CLOUDBASE_INIT_SHA256 -OutFile $msi

$p = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @(
  '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"",
  "USERNAME=$env:CLOUDBASE_INIT_USERNAME",
  'LOGGINGSERIALPORTNAME=COM1',
  'RUN_SERVICE_AS_LOCAL_SYSTEM=1'
)
if ($p.ExitCode -notin 0, 3010) {
  throw "cloudbase-init install failed with exit code $($p.ExitCode); see $log"
}
Remove-Item $msi

# Manual during the build (it would record plugin state into the image) and
# through specialize/OOBE on the deployed node, where cloudbase-init already
# runs from the sysprep answer file. SetupComplete.cmd switches it to Automatic.
Stop-Service -Name cloudbase-init -ErrorAction SilentlyContinue
Set-Service -Name cloudbase-init -StartupType Manual
