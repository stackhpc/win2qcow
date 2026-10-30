# Installed only when the image is built with bitlocker=true. cloudbase-init
# runs it from its LocalScripts folder on the deployed node, after user data.
#
# It requires a TPM 2.0 and encrypts C: with a TPM protector, then reboots so
# the next boot shows the TPM unlocks the disk by itself. Exit codes follow
# cloudbase-init's conventions:
#   1002  not finished (no usable TPM, or an error): run again at the next
#         boot, without rebooting
#   1003  BitLocker was just turned on: reboot, then run again to check it
#   0     C: is encrypted and protected by the TPM: finished
# Any other exit code would make cloudbase-init stop running the script, so
# every error is caught and turned into 1002.
#
# The status goes to C:\ProgramData\BitLocker\status.txt, the Application
# event log (source BitLockerSetup) and cloudbase-init's log and serial
# console. Events: 100 encryption started, 101 finished, 300 no usable TPM,
# 301 unexpected volume state, 302 error. The recovery password itself is
# only written to C:\ProgramData\BitLocker\recovery.txt: never to the output,
# which cloudbase-init logs.

$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramData 'BitLocker'

function Report([string]$Result, [string[]]$Details, [int]$EventId) {
  $text = @("BitLocker setup: $Result", "Time: $(Get-Date -Format o)", "Computer: $env:COMPUTERNAME") + $Details
  $text | Set-Content -Path (Join-Path $dir 'status.txt') -Encoding UTF8
  $type = if ($EventId -ge 300) { 'Error' } else { 'Information' }
  Write-EventLog -LogName Application -Source BitLockerSetup -EventId $EventId -EntryType $type -Message ($text -join "`r`n")
  $text | ForEach-Object { Write-Output $_ }
}

function Get-VolumeDetails {
  $v = Get-BitLockerVolume -MountPoint $env:SystemDrive
  # The PCRs the TPM protector is sealed to (7 and 11 when Secure Boot
  # binding is possible, otherwise 0, 2, 4 and 11).
  $pcrs = (& manage-bde.exe -protectors -get $env:SystemDrive -Type TPM | Select-String 'PCR Validation Profile' -Context 0, 1 |
    ForEach-Object { $_.Context.PostContext } | ForEach-Object { $_.Trim() }) -join ' '
  @(
    "Volume status: $($v.VolumeStatus), protection: $($v.ProtectionStatus), $($v.EncryptionPercentage)% encrypted, method $($v.EncryptionMethod)",
    "Key protectors: $(($v.KeyProtector | ForEach-Object KeyProtectorType) -join ', ')",
    "TPM PCR validation profile: $(if ($pcrs) { $pcrs } else { 'none' })"
  )
}

try {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  # Administrators and SYSTEM only, owned by Administrators: the recovery
  # password is kept here.
  & icacls.exe $dir /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
  if ($LASTEXITCODE) { throw "icacls /setowner failed with $LASTEXITCODE" }
  & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /T /C /Q | Out-Null
  if ($LASTEXITCODE) { throw "icacls /grant failed with $LASTEXITCODE" }
  if (-not [System.Diagnostics.EventLog]::SourceExists('BitLockerSetup')) {
    New-EventLog -LogName Application -Source BitLockerSetup
  }

  # The TPM: present, ready (enabled, activated, owned) and version 2.0.
  $tpm = Get-Tpm
  $initError = $null
  if ($tpm.TpmPresent -and -not $tpm.TpmReady) {
    # Windows normally provisions the TPM itself; try once more without clearing it.
    try { Initialize-Tpm -AllowClear:$false | Out-Null; $tpm = Get-Tpm } catch { $initError = "Initialize-Tpm failed: $_" }
  }
  $tpmWmi = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
  $tpmVersion = if ($tpmWmi) { ($tpmWmi.SpecVersion -split ',')[0].Trim() } else { 'none' }
  $secureBoot = try { if (Confirm-SecureBootUEFI) { 'on' } else { 'off' } } catch { 'unsupported' }
  $tpmDetails = @(
    "TPM present: $($tpm.TpmPresent), ready: $($tpm.TpmReady), enabled: $($tpm.TpmEnabled), activated: $($tpm.TpmActivated), owned: $($tpm.TpmOwned)",
    "TPM spec version: $tpmVersion, manufacturer: $($tpm.ManufacturerIdTxt) $($tpm.ManufacturerVersion)",
    "Secure Boot: $secureBoot"
  ) + @($initError | Where-Object { $_ })

  if (-not ($tpm.TpmPresent -and $tpm.TpmReady -and $tpmVersion -like '2.*')) {
    Report 'FAILED: this image requires a ready TPM 2.0. Turn the TPM on in the firmware; this check runs again at every boot.' $tpmDetails 300
    exit 1002
  }

  $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
  $protectors = @($volume.KeyProtector | ForEach-Object { $_.KeyProtectorType.ToString() })

  if ($volume.VolumeStatus -eq 'FullyDecrypted') {
    # Recovery password first, so the volume is never protected by the TPM
    # alone. Both cmdlets print a warning that contains the recovery password,
    # so warnings are discarded: this output ends up in cloudbase-init's log.
    if ($protectors -notcontains 'RecoveryPassword') {
      Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -WarningAction SilentlyContinue | Out-Null
    }
    $recovery = (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector |
      Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    @("Recovery key ID: $($recovery.KeyProtectorId)", "Recovery password: $($recovery.RecoveryPassword)") |
      Set-Content -Path (Join-Path $dir 'recovery.txt') -Encoding UTF8
    # A TPM protector left by an earlier, failed attempt (or a pending
    # hardware test) would make Enable-BitLocker fail: start again from it.
    $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Tpm' } | ForEach-Object {
      Remove-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $_.KeyProtectorId | Out-Null
    }
    # -SkipHardwareTest: encrypt now rather than after a test reboot; the
    # reboot requested below tests the TPM unlock instead.
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -UsedSpaceOnly -SkipHardwareTest `
      -TpmProtector -WarningAction SilentlyContinue | Out-Null
    Report 'ENABLED: encrypting C: with a TPM protector; rebooting to check the TPM unlocks it.' ($tpmDetails + (Get-VolumeDetails) +
      "Recovery key ID: $($recovery.KeyProtectorId) (password in $dir\recovery.txt)") 100
    exit 1003
  }

  if ($volume.VolumeStatus -eq 'EncryptionSuspended' -or $volume.ProtectionStatus -eq 'Off') {
    Resume-BitLocker -MountPoint $env:SystemDrive -WarningAction SilentlyContinue | Out-Null
  }

  # After the reboot. The deployment is unattended, so reaching this point
  # means the TPM released the key. Wait for encryption to finish (used space
  # only: minutes); cloudbase-init waits for this script.
  $deadline = (Get-Date).AddMinutes(60)
  $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
  while ($volume.VolumeStatus -eq 'EncryptionInProgress' -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
  }
  $details = $tpmDetails + (Get-VolumeDetails) +
    "Booted with the TPM protector after enabling. Boot time: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'))"
  if ($volume.VolumeStatus -eq 'FullyEncrypted' -and $volume.ProtectionStatus -eq 'On' -and
      ($volume.KeyProtector.KeyProtectorType -contains 'Tpm')) {
    Report 'OK: C: is fully encrypted and protected by the TPM.' $details 101
    exit 0
  }
  Report 'FAILED: unexpected BitLocker state; this check runs again at the next boot.' $details 301
  exit 1002
} catch {
  $message = "FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber)); this check runs again at the next boot."
  try { Report $message @() 302 } catch { Write-Output "BitLocker setup: $message"; Write-Output "Could not record the status: $_" }
  exit 1002
}
