$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$msi = Join-Path $env:TEMP 'CloudbaseInitSetup.msi'
$log = "$env:SystemRoot\Temp\cloudbase-init-install.log"

Write-Host "Downloading $env:CLOUDBASE_INIT_URL"
Invoke-WebRequest -Uri $env:CLOUDBASE_INIT_URL -OutFile $msi -UseBasicParsing

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

# The service must start automatically on the deployed node, but must not run
# during the build (it would record plugin state into the image).
Stop-Service -Name cloudbase-init -ErrorAction SilentlyContinue
Set-Service -Name cloudbase-init -StartupType Automatic
