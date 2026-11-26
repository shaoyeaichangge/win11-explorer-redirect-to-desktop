#requires -Version 5.1
<#
.SYNOPSIS
    Removes leftover ("ghost") optical-drive device records that are no longer
    present on the machine.

.DESCRIPTION
    Mass-produced USB sticks that pretend to be CD-ROMs, NIC vendor driver
    discs and mounted ISO images all leave a device record behind in
    HKLM\SYSTEM\CurrentControlSet\Enum.  They clutter the device tree and slow
    down enumeration, and some of them show up as unusable drive letters.

    Safety rules:
      * ONLY devices with Present = False are removed.  A real, connected
        optical drive is never touched.
      * The full list is printed and -Force is required for unattended runs.
      * Every InstanceId is saved to a text file before removal.
      * Reconnecting the hardware makes Windows reinstall it automatically.

.PARAMETER Class
    Device class to clean.  Defaults to CDROM.  Use 'DiskDrive' or 'USB' etc.
    for other classes, but be aware that non-present DISK devices can include
    external drives you may still want to plug in again later.

.PARAMETER Force
    Skip the interactive confirmation.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Remove-PhantomCdrom.ps1
#>
[CmdletBinding()]
param(
    [string]$Class = 'CDROM',
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Elevation required - confirming UAC ...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
                 '-Class', $Class)
    if ($Force) { $argList += '-Force' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

function Get-ClassDevices {
    return @(Get-PnpDevice -Class $Class -ErrorAction SilentlyContinue)
}

Write-Host ''
Write-Host ("=== Clean leftover {0} device records ===" -f $Class) -ForegroundColor Cyan

$all = Get-ClassDevices
Write-Host ("  devices recorded: " + $all.Count)

$targets = @($all | Where-Object { -not $_.Present })
$present = @($all | Where-Object { $_.Present })

Write-Host ''
Write-Host '  --- NOT present (to be removed) ---' -ForegroundColor Yellow
if ($targets.Count -eq 0) { Write-Host '    (none)' }
foreach ($d in $targets) { Write-Host ("   {0,-44} {1}" -f $d.FriendlyName, $d.InstanceId) }

Write-Host ''
Write-Host '  --- present (left alone) ---' -ForegroundColor Green
if ($present.Count -eq 0) { Write-Host '    (none)' }
foreach ($d in $present) { Write-Host ("   {0,-44} {1}" -f $d.FriendlyName, $d.InstanceId) }

if ($targets.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nothing to clean up.' -ForegroundColor Green
    return
}

$backup = Join-Path $PSScriptRoot ('phantom-' + $Class.ToLower() + '-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$targets | ForEach-Object { "{0}`t{1}`t{2}" -f $_.FriendlyName, $_.InstanceId, $_.Status } |
    Set-Content -Path $backup -Encoding UTF8
Write-Host ''
Write-Host ("  backup: " + $backup) -ForegroundColor DarkGray

if (-not $Force) {
    Write-Host ''
    Write-Host ("About to remove " + $targets.Count + " device record(s). No files are touched.") -ForegroundColor Yellow
    if ((Read-Host 'Type y to continue') -ne 'y') {
        Write-Host 'Cancelled - nothing changed.'
        return
    }
}

$ok = 0
$failed = @()
foreach ($d in $targets) {
    $removed = $false
    try {
        Remove-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
        $removed = $true
    } catch {
        $removed = $false
    }
    if (-not $removed) {
        & pnputil.exe /remove-device $d.InstanceId 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $removed = $true }
    }
    if ($removed) {
        $ok++
        Write-Host ("   removed  " + $d.FriendlyName) -ForegroundColor Green
    } else {
        $failed += $d
        Write-Host ("   FAILED   " + $d.FriendlyName + "  (" + $d.InstanceId + ")") -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ("  removed: $ok / " + $targets.Count)
if ($failed.Count) {
    Write-Host '  the rest is usually locked by the active device tree - reboot and run again.' -ForegroundColor Yellow
}

$after = Get-ClassDevices
Write-Host ''
Write-Host ("  {0} devices now recorded: {1}" -f $Class, $after.Count)
foreach ($d in $after) {
    $state = if ($d.Present) { 'present' } else { 'ghost' }
    Write-Host ("   [{0,-7}] {1,-44} {2}" -f $state, $d.FriendlyName, $d.InstanceId)
}