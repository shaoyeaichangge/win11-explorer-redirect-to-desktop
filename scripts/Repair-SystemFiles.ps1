#requires -Version 5.1
<#
.SYNOPSIS
    DISM + SFC system file repair, plus detection/removal of a dead WSUS policy
    that silently blocks Windows Update.

.DESCRIPTION
    Runs the standard repair chain:

        DISM /Online /Cleanup-Image /RestoreHealth
        sfc /scannow

    then inspects both the machine and user Windows Update policies for a
    WSUS server that does not answer.  When Windows Update is pointed at
    http://127.0.0.1:8530 (or any unreachable host) the update client fails
    with 0x80240438 and the machine silently stops receiving security fixes.

    If such a policy is found, it is exported to a .reg backup and you are
    asked before anything is deleted.

.PARAMETER SkipRepair
    Only inspect the update policy; do not run DISM/SFC (much faster).

.PARAMETER Force
    Remove an unreachable WSUS policy without asking.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-SystemFiles.ps1 -SkipRepair

.NOTES
    DISM/SFC take 10-40 minutes and need administrator rights.
    The policy fix needs a restart of the Windows Update service to take effect.
#>
[CmdletBinding()]
param(
    [switch]$SkipRepair,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevation required - confirming UAC ...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($SkipRepair) { $argList += '-SkipRepair' }
    if ($Force) { $argList += '-Force' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

$policyKeys = @(
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
    'HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
)

Write-Host ''
Write-Host '=== Windows Update policy check ===' -ForegroundColor Cyan
$found = @()
foreach ($k in $policyKeys) {
    $out = & reg.exe query $k 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { continue }
    Write-Host ("  [$k]") -ForegroundColor Yellow
    $out | Where-Object { $_ -match '\S\S\s+\S' } | ForEach-Object { Write-Host ("     " + $_.Trim()) }
    $found += $k
}

if ($found.Count -eq 0) {
    Write-Host '  no Windows Update policy present - updates go straight to Microsoft.' -ForegroundColor Green
} else {
    $server = $null
    foreach ($k in $found) {
        $v = (& reg.exe query $k /v WUServer 2>$null) -join "`n"
        if ($v -match 'WUServer\s+REG_SZ\s+(\S+)') { $server = $Matches[1] }
    }
    if ($server) {
        Write-Host ''
        Write-Host ("  WUServer = $server") -ForegroundColor Yellow
        $reachable = $false
        try {
            $uri = [uri]$server
            $reachable = (Test-NetConnection -ComputerName $uri.Host -Port $uri.Port -InformationLevel Quiet -WarningAction SilentlyContinue)
        } catch { $reachable = $false }
        if ($reachable) {
            Write-Host '  the WSUS server answers - policy left untouched.' -ForegroundColor Green
        } else {
            Write-Host '  the WSUS server does NOT answer: Windows Update is silently broken.' -ForegroundColor Red
            $doRemove = $Force
            if (-not $Force) {
                $doRemove = ((Read-Host '  Export a backup and remove this policy now? [y/N]') -eq 'y')
            }
            if ($doRemove) {
                $backup = Join-Path $PSScriptRoot ('wupolicy-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.reg')
                & reg.exe export 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' $backup /y | Out-Null
                Write-Host ("  backup: " + $backup) -ForegroundColor DarkGray
                & reg.exe delete 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' /f | Out-Null
                Write-Host '  policy removed.' -ForegroundColor Green
                Restart-Service wuauserv -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Write-Host '  wuauserv restarted - open Settings > Windows Update and check for updates.'
            } else {
                Write-Host '  left in place.'
            }
        }
    }
}

if ($SkipRepair) { return }

Write-Host ''
Write-Host '=== DISM restore health (10-30 min) ===' -ForegroundColor Cyan
& DISM.exe /Online /Cleanup-Image /RestoreHealth
Write-Host ("  DISM exit code: " + $LASTEXITCODE)

Write-Host ''
Write-Host '=== SFC scan (5-20 min) ===' -ForegroundColor Cyan
& sfc.exe /scannow
Write-Host ("  SFC exit code: " + $LASTEXITCODE)

Write-Host ''
Write-Host 'Done. Reboot before judging the result.' -ForegroundColor Green