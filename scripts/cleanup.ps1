$ErrorActionPreference = 'Stop'

# Shrink the component store; superseded components can't be uninstalled afterwards,
# which is fine for a golden image.
& dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
if ($LASTEXITCODE -ne 0) { throw "DISM component cleanup failed with exit code $LASTEXITCODE" }

Get-ChildItem -Path $env:TEMP, "$env:SystemRoot\Temp" -Exclude 'sysprep.ps1', 'packer-*', 'script-*' -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# Hand freed blocks back to QEMU (disk_discard=unmap) so the qcow2 stays small.
Optimize-Volume -DriveLetter C -ReTrim -Verbose
