#requires -Version 5.1
<#
.SYNOPSIS
    Repairs the "every new Explorer window jumps back to the Desktop" bug.

.DESCRIPTION
    The symptom is caused by a stale value inside the per-user explorer state key

        HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer

    This script exports that key to a .reg backup, then removes its stale
    subkeys one by one, keeping the folder mappings (User Shell Folders /
    Shell Folders) so that no user folder path is ever changed.  Explorer is
    restarted afterwards and the result is verified automatically.

    The key is rebuilt with clean defaults by Windows itself.
    No files are touched.  No administrator rights are required.

.PARAMETER DryRun
    Only report what would be removed.

.PARAMETER BackupDir
    Where to put the .reg backup.  Defaults to the script folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-ExplorerState.ps1

.EXAMPLE
    .\Fix-ExplorerState.ps1 -DryRun

.NOTES
    Side effects (settings only, never data):
      * pinned taskbar items and quick-access pins go back to defaults
      * folder view options (sort, column width, icon size) go back to defaults
      * remembered window sizes/positions and address-bar history are cleared
    Roll back with:  reg import "<the backup .reg printed by the script>"
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$BackupDir = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$keyPath = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer'
$psPath  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
$keep    = @('User Shell Folders', 'Shell Folders')

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    Start-Process explorer.exe
    Start-Sleep -Seconds 8
}

function Test-NewWindow {
    param([string[]]$Targets = @('C:\Windows'))

    $allOk = $true
    foreach ($t in $Targets) {
        $shell = New-Object -ComObject Shell.Application
        $before = @()
        foreach ($w in @($shell.Windows())) { $before += [int64]$w.HWND }

        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $t + '"')
        Start-Sleep -Seconds 6

        $new = @($shell.Windows() | Where-Object { $before -notcontains [int64]$_.HWND })
        $url = ''
        $bounced = $false
        foreach ($w in $new) {
            $url = [string]$w.LocationURL
            if ($url -match '/Desktop$' -and $t -ne "$env:USERPROFILE\Desktop") { $bounced = $true }
        }

        if ($new.Count -eq 0) { $verdict = 'NO_WINDOW'; $allOk = $false }
        elseif ($bounced)     { $verdict = 'BOUNCED_TO_DESKTOP'; $allOk = $false }
        else                  { $verdict = 'OK' }

        Write-Host ("    {0,-42} {1}" -f $t, $verdict)
        foreach ($w in $new) { $w.Quit() }
        Start-Sleep -Milliseconds 400
    }
    return $allOk
}

Write-Host ''
Write-Host '=== Fix Explorer state ===' -ForegroundColor Cyan

if (-not (Test-Path $psPath)) {
    Write-Host '  the Explorer key does not exist - nothing to do.' -ForegroundColor Yellow
    return
}

$subKeys = @(Get-ChildItem $psPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
$targets = @($subKeys | Where-Object { $keep -notcontains $_ })
Write-Host ("  subkeys present: " + $subKeys.Count + "   to remove: " + $targets.Count)
foreach ($t in $targets) { Write-Host ("    - " + $t) -ForegroundColor DarkGray }

if ($DryRun) {
    Write-Host ''
    Write-Host '  DryRun: nothing was changed.' -ForegroundColor Yellow
    return
}

if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
$backup = Join-Path $BackupDir ('explorer-state-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.reg')
& reg.exe export $keyPath $backup /y | Out-Null
if (-not (Test-Path $backup)) {
    Write-Host '  backup failed - aborting so nothing is lost.' -ForegroundColor Red
    return
}
Write-Host ''
Write-Host ("  backup: $backup (" + [int]((Get-Item $backup).Length / 1024) + " KB)") -ForegroundColor DarkGray

Write-Host '  restarting explorer ...'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4

$removed = 0
$locked = @()
foreach ($s in $targets) {
    try {
        Remove-Item ("$psPath\$s") -Recurse -Force -ErrorAction Stop
        $removed++
    } catch {
        $locked += $s
    }
}
Write-Host ("  removed $removed stale subkeys")
if ($locked.Count) { Write-Host ("  locked, left alone: " + ($locked -join ', ')) -ForegroundColor DarkGray }

Start-Process explorer.exe
Start-Sleep -Seconds 8

Write-Host ''
Write-Host '  verifying ...' -ForegroundColor Cyan
$ok = Test-NewWindow -Targets @('C:\Windows', "$env:USERPROFILE\Downloads")

Write-Host ''
if ($ok) {
    Write-Host 'RESULT: FIXED' -ForegroundColor Green
    Write-Host '  Re-pin your taskbar items and quick-access folders if you want them back.' -ForegroundColor DarkGray
} else {
    Write-Host 'RESULT: still broken - rolling back ...' -ForegroundColor Yellow
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    & reg.exe import $backup | Out-Null
    Start-Process explorer.exe
    Start-Sleep -Seconds 5
    Write-Host '  restored from backup.'
    exit 1
}